defmodule MinutemodemMobile.Cp2102 do
  @moduledoc """
  Silicon Labs CP2102/CP210x USB-UART control-transfer encoder.

  The CP210x is the serial bridge inside a DigiRig (and many ham-radio CAT
  cables). Its UART configuration and modem-handshake lines (RTS/DTR) are
  driven over the USB **control** endpoint, not bulk — so this module sits on
  top of `Mob.VendorUsb.control_transfer/7`, the framework's generic control
  primitive. All SiLabs-specific request codes and value encodings live here;
  the framework stays device-agnostic.

  For the DigiRig the radio's PTT is wired to the CP2102's **RTS** line, so
  keying the transmitter is `set_rts(socket, session, true)` and unkeying is
  `set_rts(socket, session, false)`. Before any of that works the UART must be
  enabled once with `enable(socket, session)`.

  Constants and the control-transfer shapes follow the reference SiLabs
  AN571 register map (and the `usb-serial-for-android` Cp21xx driver):

      enable/2     IFC_ENABLE,  value = UART_ENABLE,  host→device, no data
      set_baud/3   SET_BAUDRATE, value = 0, index = port, host→device,
                   4-byte little-endian baud in the data payload
      set_rts/3    SET_MHS,     value = RTS_ENABLE | RTS_DISABLE, host→device
      set_dtr/3    SET_MHS,     value = DTR_ENABLE | DTR_DISABLE, host→device
      status/2     GET_MDMSTS,  device→host, reads one modem-status byte

  Each call returns the socket unchanged (the underlying NIF is async). The
  result of every transfer arrives as
  `{:peripheral, :vendor_usb, :control_result, session, %{result: n, data: bin}}`
  — see `Mob.VendorUsb.control_transfer/7`. A `result` of `0` means the
  transfer was acknowledged with no data phase (the normal success code for
  the value-only requests below); a negative `result` is an error.

  ## DigiRig identity

  The DigiRig's serial bridge enumerates as VID `0x10C4` / PID `0xEA60`
  (`@vid` / `@pid` below) — use those with `Mob.VendorUsb.list_devices/2`.
  """

  alias Mob.VendorUsb

  # ── Device identity ──────────────────────────────────────────────────────
  @vid 0x10C4
  @pid 0xEA60

  # ── Request types (bmRequestType) ────────────────────────────────────────
  @reqtype_host_to_device 0x41
  @reqtype_device_to_host 0xC1

  # ── Request codes (bRequest) ─────────────────────────────────────────────
  @ifc_enable 0x00
  @set_line_ctl 0x03
  @set_mhs 0x07
  @get_mdmsts 0x08
  @set_baudrate 0x1E

  # ── IFC_ENABLE values ────────────────────────────────────────────────────
  @uart_enable 0x0001
  @uart_disable 0x0000

  # ── SET_MHS values (modem handshake: high byte = line mask, low = state) ──
  @dtr_enable 0x0101
  @dtr_disable 0x0100
  @rts_enable 0x0202
  @rts_disable 0x0200

  # ── GET_MDMSTS status bits ───────────────────────────────────────────────
  @status_cts 0x10
  @status_dsr 0x20
  @status_ri 0x40
  @status_cd 0x80

  @default_port 0

  @doc "DigiRig / CP210x USB vendor id (`0x10C4`)."
  def vid, do: @vid
  @doc "DigiRig / CP210x USB product id (`0xEA60`)."
  def pid, do: @pid

  @doc """
  Enable the CP210x UART. Must be called once after `Mob.VendorUsb.open/2`
  before line-coding or handshake requests take effect.
  """
  @spec enable(Mob.Socket.t(), VendorUsb.session(), keyword()) :: Mob.Socket.t()
  def enable(socket, session, opts \\ []) do
    set_config(socket, session, @ifc_enable, @uart_enable, opts)
  end

  @doc "Disable the CP210x UART."
  @spec disable(Mob.Socket.t(), VendorUsb.session(), keyword()) :: Mob.Socket.t()
  def disable(socket, session, opts \\ []) do
    set_config(socket, session, @ifc_enable, @uart_disable, opts)
  end

  @doc """
  Set the UART baud rate. The CP210x takes the rate as a 4-byte
  little-endian integer in the control-transfer data payload (not the
  legacy baud-divisor index scheme). 115200 is a safe default for CAT.
  """
  @spec set_baud(Mob.Socket.t(), VendorUsb.session(), non_neg_integer(), keyword()) ::
          Mob.Socket.t()
  def set_baud(socket, session, baud, opts \\ []) when is_integer(baud) and baud > 0 do
    port = Keyword.get(opts, :port, @default_port)
    data = <<baud::little-unsigned-32>>
    VendorUsb.control_transfer(socket, session, @reqtype_host_to_device, @set_baudrate, 0, port, data, opts)
  end

  @doc """
  Set line control: data bits, parity, and stop bits, packed into wValue per
  the SiLabs SET_LINE_CTL encoding (`data_bits <<< 8 | parity <<< 4 | stop`).
  Defaults to 8N1, which is what virtually all CAT protocols use.

  `parity`: `0` none, `1` odd, `2` even, `3` mark, `4` space.
  `stop`: `0` 1 bit, `1` 1.5 bits, `2` 2 bits.
  """
  @spec set_line_ctl(Mob.Socket.t(), VendorUsb.session(), keyword()) :: Mob.Socket.t()
  def set_line_ctl(socket, session, opts \\ []) do
    # Clamp each field to its valid range before packing into the 16-bit wValue,
    # so a bad opt can never produce an out-of-range value on the USB wire.
    data_bits = opts |> Keyword.get(:data_bits, 8) |> clamp(5, 8)
    parity = opts |> Keyword.get(:parity, 0) |> clamp(0, 4)
    stop = opts |> Keyword.get(:stop, 0) |> clamp(0, 2)
    value = Bitwise.bsl(data_bits, 8) |> Bitwise.bor(Bitwise.bsl(parity, 4)) |> Bitwise.bor(stop)
    set_config(socket, session, @set_line_ctl, value, opts)
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_n, lo, _hi), do: lo

  @doc """
  Assert or deassert RTS. On a DigiRig this is the PTT line: `true` keys the
  transmitter, `false` returns to receive.
  """
  @spec set_rts(Mob.Socket.t(), VendorUsb.session(), boolean(), keyword()) :: Mob.Socket.t()
  def set_rts(socket, session, true, opts), do: set_config(socket, session, @set_mhs, @rts_enable, opts)
  def set_rts(socket, session, false, opts), do: set_config(socket, session, @set_mhs, @rts_disable, opts)
  def set_rts(socket, session, on?), do: set_rts(socket, session, on?, [])

  @doc "Assert or deassert DTR (a second keying line on some interfaces)."
  @spec set_dtr(Mob.Socket.t(), VendorUsb.session(), boolean(), keyword()) :: Mob.Socket.t()
  def set_dtr(socket, session, true, opts), do: set_config(socket, session, @set_mhs, @dtr_enable, opts)
  def set_dtr(socket, session, false, opts), do: set_config(socket, session, @set_mhs, @dtr_disable, opts)
  def set_dtr(socket, session, on?), do: set_dtr(socket, session, on?, [])

  @doc "Convenience: key PTT (RTS high)."
  @spec key(Mob.Socket.t(), VendorUsb.session(), keyword()) :: Mob.Socket.t()
  def key(socket, session, opts \\ []), do: set_rts(socket, session, true, opts)

  @doc "Convenience: unkey PTT (RTS low)."
  @spec unkey(Mob.Socket.t(), VendorUsb.session(), keyword()) :: Mob.Socket.t()
  def unkey(socket, session, opts \\ []), do: set_rts(socket, session, false, opts)

  @doc """
  Request the modem status byte (CTS/DSR/RI/CD). The byte arrives in the
  `:data` field of the `:control_result` message; decode it with
  `decode_status/1`.
  """
  @spec status(Mob.Socket.t(), VendorUsb.session(), keyword()) :: Mob.Socket.t()
  def status(socket, session, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    # device→host: a 1-byte read buffer sizes the IN transfer.
    VendorUsb.control_transfer(socket, session, @reqtype_device_to_host, @get_mdmsts, 0, port, <<0>>, opts)
  end

  @doc """
  Decode a GET_MDMSTS status byte into a map of the four input-line booleans.
  Pass the `data` binary from the `:control_result` message.
  """
  @spec decode_status(binary()) :: %{cts: boolean(), dsr: boolean(), ri: boolean(), cd: boolean()}
  def decode_status(<<byte>>) do
    %{
      cts: Bitwise.band(byte, @status_cts) != 0,
      dsr: Bitwise.band(byte, @status_dsr) != 0,
      ri: Bitwise.band(byte, @status_ri) != 0,
      cd: Bitwise.band(byte, @status_cd) != 0
    }
  end

  def decode_status(_), do: %{cts: false, dsr: false, ri: false, cd: false}

  # ── Internal ─────────────────────────────────────────────────────────────

  # The SiLabs value-only requests (IFC_ENABLE, SET_MHS, SET_LINE_CTL) carry
  # their argument in wValue with no data phase. wIndex is the port number.
  defp set_config(socket, session, request, value, opts) do
    port = Keyword.get(opts, :port, @default_port)
    VendorUsb.control_transfer(socket, session, @reqtype_host_to_device, request, value, port, <<>>, opts)
  end
end
