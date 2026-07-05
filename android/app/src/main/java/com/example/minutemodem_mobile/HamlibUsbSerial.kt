package com.example.minutemodem_mobile

import android.content.Context
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.util.Log

/**
 * Synchronous CP2102/CP210x USB-serial driver backing Hamlib's Android serial
 * bridge (the `hlx_android_usb_serial_*` host contract in
 * hamlib_ex/android/hamlib/src/android_serial_bridge.c).
 *
 * The bridge runs a pump thread inside libhamlib that calls the C host contract
 * synchronously; those C functions (in hamlib_nif) JNI-upcall the @JvmStatic
 * methods here. We drive the CP2102 directly with blocking
 * UsbDeviceConnection.bulkTransfer (read/write) and controlTransfer (the SiLabs
 * IFC_ENABLE / SET_BAUDRATE / SET_LINE_CTL / SET_MHS vendor requests). Same
 * request codes as MinutemodemMobile.Cp2102, but exercised here rather than via
 * Mob.VendorUsb, because Hamlib needs a synchronous byte stream.
 *
 * Ownership: this driver owns the CP2102 while CAT is open (DigiRig serial line
 * = CAT + RTS/PTT). The modem Manager keeps only the CM108 audio; PTT is issued
 * by Hamlib (rig_set_ptt -> our set_rts) once CAT is up.
 */
object HamlibUsbSerial {
    private const val TAG = "HamlibUsbSerial"

    // ── SiLabs CP210x vendor protocol (mirrors MinutemodemMobile.Cp2102) ──────
    private const val VID = 0x10C4
    private const val PID = 0xEA60
    private const val REQTYPE_HOST_TO_DEVICE = 0x41
    private const val IFC_ENABLE = 0x00
    private const val SET_LINE_CTL = 0x03
    private const val SET_MHS = 0x07
    private const val SET_BAUDRATE = 0x1E
    private const val UART_ENABLE = 0x0001
    private const val RTS_ENABLE = 0x0202
    private const val RTS_DISABLE = 0x0200
    private const val DTR_ENABLE = 0x0101
    private const val DTR_DISABLE = 0x0100

    private val lock = Any()
    @Volatile private var conn: UsbDeviceConnection? = null
    private var iface: UsbInterface? = null
    private var epIn: UsbEndpoint? = null
    private var epOut: UsbEndpoint? = null
    private var portIndex: Int = 0

    // ── Host contract (called from the JNI shim) ─────────────────────────────

    /** 1 if a CP2102 is present and permission is held, else 0. */
    @JvmStatic
    fun isReady(): Int {
        val ctx = MobBridge.currentActivity() ?: return 0
        val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return 0
        val dev = findCp2102(mgr) ?: return 0
        return if (mgr.hasPermission(dev)) 1 else 0
    }

    /** Open + configure the CP2102. Returns 0 on success, non-zero on failure. */
    @JvmStatic
    fun open(
        deviceId: Int,
        port: Int,
        baud: Int,
        dataBits: Int,
        stopBits: Int,
        parity: Int
    ): Int = synchronized(lock) {
        try {
            closeLocked()
            val ctx = MobBridge.currentActivity() ?: return 1
            val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return 1

            val dev =
                (if (deviceId > 0) mgr.deviceList.values.firstOrNull { it.deviceId == deviceId }
                else null) ?: findCp2102(mgr) ?: run {
                    Log.w(TAG, "no CP2102 device found (deviceId=$deviceId)")
                    return 2
                }

            if (!mgr.hasPermission(dev)) {
                Log.w(TAG, "no USB permission for ${dev.deviceName}")
                return 3
            }

            val c = mgr.openDevice(dev) ?: run { Log.w(TAG, "openDevice failed"); return 4 }
            val intf = dev.getInterface(0)
            if (!c.claimInterface(intf, true)) {
                c.close(); Log.w(TAG, "claimInterface failed"); return 5
            }

            var inEp: UsbEndpoint? = null
            var outEp: UsbEndpoint? = null
            for (i in 0 until intf.endpointCount) {
                val ep = intf.getEndpoint(i)
                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                    if (ep.direction == UsbConstants.USB_DIR_IN) inEp = ep else outEp = ep
                }
            }
            if (inEp == null || outEp == null) {
                c.releaseInterface(intf); c.close(); Log.w(TAG, "no bulk endpoints"); return 6
            }

            portIndex = port
            // IFC_ENABLE, baud, line control (data/parity/stop packed per SiLabs).
            ctl(c, IFC_ENABLE, UART_ENABLE)
            ctlData(c, SET_BAUDRATE, 0, leU32(if (baud > 0) baud else 19200))
            val lineCtl = (clamp(dataBits, 5, 8) shl 8) or (clamp(parity, 0, 4) shl 4) or clamp(stopBits, 1, 2)
            ctl(c, SET_LINE_CTL, lineCtl)
            // Deassert RTS and DTR so PTT is definitely OFF (RX) during CAT open;
            // Hamlib keys RTS itself for PTT. A stuck-asserted RTS would hold the
            // radio in transmit and it could never answer CI-V.
            ctl(c, SET_MHS, RTS_DISABLE)
            ctl(c, SET_MHS, DTR_DISABLE)

            conn = c; iface = intf; epIn = inEp; epOut = outEp
            Log.i(TAG, "CP2102 open ok: ${dev.deviceName} baud=$baud data=$dataBits stop=$stopBits parity=$parity")
            0
        } catch (e: Exception) {
            Log.w(TAG, "open exception: $e")
            9
        }
    }

    /** Blocking read up to [length] bytes. Returns bytes read (>0), 0 on timeout, <0 on error. */
    @JvmStatic
    fun read(buffer: ByteArray, length: Int, timeoutMs: Int): Int {
        val c = conn ?: return -1
        val ep = epIn ?: return -1
        val n = c.bulkTransfer(ep, buffer, minOf(length, buffer.size), timeoutMs)
        // bulkTransfer returns -1 on timeout or error; treat as 0 (no data) so the
        // pump keeps polling rather than tearing the port down.
        if (n > 0) Log.i(TAG, "read $n bytes: ${hex(buffer, n)}")
        return if (n < 0) 0 else n
    }

    /** Blocking write. Returns bytes written (>0), <=0 on error. */
    @JvmStatic
    fun write(data: ByteArray, length: Int, timeoutMs: Int): Int {
        val c = conn ?: return -1
        val ep = epOut ?: return -1
        val n = c.bulkTransfer(ep, data, minOf(length, data.size), timeoutMs)
        Log.i(TAG, "write $n/$length: ${hex(data, if (n > 0) n else length)}")
        return n
    }

    private fun hex(b: ByteArray, n: Int): String =
        (0 until minOf(n, 24)).joinToString(" ") { "%02X".format(b[it]) }

    @JvmStatic
    fun setRts(state: Int): Int {
        val c = conn ?: return 1
        return if (ctl(c, SET_MHS, if (state != 0) RTS_ENABLE else RTS_DISABLE) >= 0) 0 else 1
    }

    @JvmStatic
    fun setDtr(state: Int): Int {
        val c = conn ?: return 1
        return if (ctl(c, SET_MHS, if (state != 0) DTR_ENABLE else DTR_DISABLE) >= 0) 0 else 1
    }

    @JvmStatic
    fun flush(): Int = 0

    @JvmStatic
    fun close(): Int = synchronized(lock) {
        closeLocked()
        0
    }

    // ── internals ─────────────────────────────────────────────────────────────

    private fun closeLocked() {
        val c = conn
        val i = iface
        if (c != null && i != null) {
            try { c.releaseInterface(i) } catch (_: Exception) {}
        }
        try { c?.close() } catch (_: Exception) {}
        conn = null; iface = null; epIn = null; epOut = null
    }

    private fun findCp2102(mgr: UsbManager): UsbDevice? =
        mgr.deviceList.values.firstOrNull { it.vendorId == VID && it.productId == PID }

    // Value-only SiLabs control request (host->device, no data phase).
    private fun ctl(c: UsbDeviceConnection, request: Int, value: Int): Int =
        c.controlTransfer(REQTYPE_HOST_TO_DEVICE, request, value, portIndex, null, 0, 200)

    // SiLabs control request carrying a data payload (SET_BAUDRATE: 4-byte LE).
    private fun ctlData(c: UsbDeviceConnection, request: Int, value: Int, data: ByteArray): Int =
        c.controlTransfer(REQTYPE_HOST_TO_DEVICE, request, value, portIndex, data, data.size, 200)

    private fun leU32(v: Int): ByteArray =
        byteArrayOf(
            (v and 0xFF).toByte(),
            ((v shr 8) and 0xFF).toByte(),
            ((v shr 16) and 0xFF).toByte(),
            ((v shr 24) and 0xFF).toByte()
        )

    private fun clamp(n: Int, lo: Int, hi: Int): Int = if (n < lo) lo else if (n > hi) hi else n
}
