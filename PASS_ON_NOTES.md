# MinuteModem Mobile — Pass-On Notes

_Last updated: 2026-06-27, end of the serial-USB-plumbing session._
_Transcript: `2026-06-27-05-46-28-minutemodem-serial-usb-plumbing.txt`_

This file is the running engineering state for the next session. It is the
durable form of what used to live only in the compaction summary. Update the
"STATUS" and "NEXT STEPS" sections at the end of each session.

---

## THE GOAL

"The phone IS the modem." A DigiRig over OTG USB carries both the modem audio
(CM108 codec) and the rig control (CP2102 serial; PTT = RTS). milwave-rs DSP
runs on-device on the BEAM. Two native capabilities through the Mob framework:
real-time PCM audio I/O pinned to the USB codec, and USB serial that can set
line-coding and assert RTS for PTT.

---

## STATUS (where the goal stands)

**Audio RX path: BUILT + HARDWARE-PROVEN.** The real-time PCM duplex bridge is
built, correctness-hardened, and validated on the real DigiRig over wifi adb:
enumeration sees the CM108 as a full-duplex USB pair (capture id 6826 /
playback id 6818), `open` pins both directions and the HAL honours the pin,
UNPROCESSED capture is granted (`source: 9`, bit-exact for modem tones), and
PCM frames flow end-to-end Kotlin→JNI→zig→BEAM. Committed `b3bde47` (bridge) +
`609e2ab` (correctness pass). The phone can HEAR the radio.

**Serial / PTT path: BUILT + DISPATCH-PROVEN, hardware-pending.** The generic
`vendor_usb_control_transfer` primitive is written across all five layers
(zig NIF + delivery + struct field + cacheOptional + table entry; the three
mob_nif.erl stub places; Kotlin method + delivery external; JNI thunk +
forward-decl; `Mob.VendorUsb.control_transfer/7` + `:control_result` normalize
clause). Plus the app-side `MinutemodemMobile.Cp2102` module encoding the
SiLabs sequences. Committed `53db550`.
- Compiles on every layer (`mix deps.compile mob --force` OK; native deploy
  `BUILD SUCCESSFUL`).
- Loads + dispatches on-device (USB adb): NIF registered with a consistent
  table (no inconsistency crash at load), Elixir wrappers + Cp2102 loaded, and
  a bogus-session dispatch round-tripped NIF→Kotlin→JNI→zig→BEAM returning
  `{:peripheral, :vendor_usb, :error, 999999, :no_session}`.
- NOT yet physically confirmed: that RTS actually keys the rig. Blocked only by
  the DigiRig needing the USB-C port (so it needs wifi adb on a trusted
  network — the last session was on a hostile WLAN with USB-only adb).

**Theoretical position:** the full software stack for a *transmitting* radio
exists and is proven to load. The phone can listen; in code it can now also key
the transmitter and set the line. Remaining to a working keyed transmitter is
one hardware test session, not new construction.

---

## COMMIT STATE

Branch `chore/mob-0.7.5`, **6 commits ahead of origin, UNPUSHED**:
```
53db550 feat(serial): generic USB control_transfer primitive + CP2102 PTT
609e2ab fix(audio): correctness pass on PCM bridge; proven on DigiRig hardware
b3bde47 feat(audio): real-time PCM duplex bridge for pinned USB+BLE capture
97a5d80 style(android): theme the drawer chrome; drop dead screen handlers
2b61e03 feat(android): add ModalNavigationDrawer render case (MobDrawer)
45a64cd feat(ui): self-driven nav shell with Config/Network views
bf7069b (origin) fix(android): reconcile generated native layer w/ mob 0.7.5
```
The `deps/mob/` edits (zig audio_pcm + control_transfer, mob_nif.erl stubs,
beam_jni.c thunks, Mob.VendorUsb.control_transfer) live ON DISK + compiled but
are in the DEPENDENCY tree, so they do NOT appear in app git status. They are
the eventual upstream surface (genericjam/mob).

---

## NEXT STEPS (priority order)

1. **[HARDWARE — the big one] Prove RTS keys the rig.** On a trusted network:
   wifi adb up, DigiRig on USB-C, then via the Code.eval_string probe harness:
   `Mob.VendorUsb.list_devices(vendor_id: 0x10C4)` → `request_permission` →
   `open` the CP2102 interface → `Cp2102.enable(socket, session)` →
   `Cp2102.set_baud(socket, session, 115200)` →
   `Cp2102.set_rts(socket, session, true)` and watch the rig key; confirm
   `set_rts(..., false)` drops it. This is the first keyed carrier.
2. **[audio] In-app mic permission** via `Mob.Permissions.request(socket,
   :microphone)` at startup. Currently an `adb pm grant` shortcut; a fresh
   install won't have it. The `"microphone" -> RECORD_AUDIO` mapping already
   exists in MobBridge.kt request_permission.
3. **[GenServer — the next engineering milestone] Supervising GenServer** that
   owns both the audio sessions and the rig control: half-duplex T/R gating
   (key PTT → suppress the RX zero-detector → unkey → re-enable), recovery on
   `:dead` (bounded backoff re-open), TX inhibition. The bridge already EMITS
   every event this needs; the policy consumer isn't written.
4. **[rig] Replace `Rig.StubControl`** with a real `Cp2102`-backed
   `Minutewave.Rig.Control.Behaviour` implementation, so the existing
   rig/modem/ALE machinery drives hardware instead of the in-memory stub.
   (Stub is at `lib/minutemodem_mobile/rig/stub_control.ex`; Cp2102 protocol
   layer is at `lib/minutemodem_mobile/rig/cp2102.ex`.)
5. **[DSP] Wire milwave-rs** to the proven PCM path: RX demod from
   `{:audio_pcm, :data}`; TX = modulate → `audio_pcm_write` → key via Cp2102 →
   transmit → unkey.
6. **[audio — GATED on Shokz BLE hardware] Dual-capture probe.** Open a SECOND
   PCM stream pinned to the Shokz BLE headset (TYPE_BLE_HEADSET=26) concurrently
   with the DigiRig stream; confirm both `record_routed_id` match AND both
   deliver non-zero `{:audio_pcm, :data}`. Last HAL-concurrency unknown for the
   always-on two-domain (modem + voice) design. NOT on the critical path to a
   basic transmitting modem.
7. **[packaging] Extract audio + serial into Mob Tier-1 plugin(s)** via
   `mix mob.new_plugin --tier 1` — structurally prevents the NIF-table-
   inconsistency crash class (scaffold generates stub↔table as one validated
   unit). `mob_audio_stream`/MobAudioStream and a serial analog. Sanctioned
   upstream path.
8. **[git] Push branch** `chore/mob-0.7.5` (6 ahead) when ready.
9. **[upstream] Contribute to genericjam/mob:** control_transfer + PCM-duplex
   primitives + the MobDrawer "drawer" render case.

---

## ENVIRONMENT & TOOLING (learned empirically — read before driving)

**Tool routing (critical):**
- The Mac source tree `/Users/mac.w/src` is reachable via the **filesystem
  MCP** (read_text_file/write_file — writes DO reach disk; verify after) and
  **tmux** (send_keys). The `str_replace`/`view`/`create_file`/`bash_tool`
  computer-use tools operate on a DIFFERENT container filesystem, NOT the Mac —
  `str_replace` on a `/Users/mac.w/...` path fails "File not found".
- The transcripts + journal live at `/mnt/transcripts/` which is on the
  CONTAINER side (reach via `bash_tool`), NOT the Mac (tmux can't see it) and
  NOT the filesystem MCP (outside `/Users/mac.w/src`).
- For zig/Kotlin/erl/C edits: write a Python edit script via
  `filesystem:write_file` with `replace_once()` assertions, run via tmux
  `python3`. This AVOIDS tmux heredoc mangling. Same for commit messages:
  write `.cm.txt`, `git commit -F .cm.txt`.

**tmux:** socket `claude_workspace` (LIBTMUX_SOCKET). Session `refactor4`
(id `$0`). Main pane `%0` (zsh, macOS BSD tools). A second window `@1`/pane `%1`
named `tunnel` was created for the dist tunnel. The user SHARES pane `%0` —
their `ssh root@dockerdev-1-co-wsll` sometimes appears mid-session; ALWAYS
verify host with `hostname` before sending (correct = `L21360`, wrong =
`root@dockerdev-1-co-wsll`).
- Sync: MOST RELIABLE is appending `; tmux wait-for -S <chan>` to the send_keys
  payload + `wait_for_channel`. `wait_for_text` on a `marker_$RANDOM` sentinel
  frequently races/times out on this shared pane.
- zsh gotcha: bare globs like `.*.py` fail "no matches found"; use explicit
  names or `2>/dev/null || echo CLEAN`.

**Phone:** OnePlus CPH2451/OP594DL1, arm64, Android 16, USB adb serial
`19080e11`. Wifi adb (when on a trusted net): phone IP has been
`192.168.217.52`, `adb connect 192.168.217.52:5555`. Setup: get IP via
`adb -s 19080e11 shell ip route | grep -oE 'src [0-9.]+'`; `adb -s 19080e11
tcpip 5555; sleep 2; adb connect <ip>:5555`. Wifi persists after USB unplug →
solves the one-port problem (DigiRig owns USB-C, wifi keeps deploy/log/dist).
- `pidof minutemodem_mobile` over adb returns EMPTY even when alive (name
  truncation) — DON'T trust it; use `adb -s <dev> shell ps -A | grep -i
  minutemodem`.

**Deploy:** `mix mob.deploy --native --device <serial-or-ip:port>`. `--native`
recompiles Kotlin/zig/JNI/C; plain deploy pushes only `.beam`. Success markers:
"BUILD SUCCESSFUL", "Android native build complete", "Deployed to N device(s)".
- **CRITICAL:** editing anything in `deps/mob/src/*.erl` REQUIRES
  `mix deps.compile mob --force` BEFORE deploy (mix does NOT recompile deps on
  source change; stale `.beam` → NIF inconsistency crash at load).

**On-device test harness (PROVEN):**
- The dist tunnel runs over an adb port-forward: `adb -s <dev> forward tcp:9100
  tcp:9100`. Device node = `minutemodem_mobile_android_19080e11@127.0.0.1`,
  port 9100, cookie `mob_secret`.
- `mix mob.connect --no-iex --device <dev>` sets up the forward + epmd
  registration BUT THEN EXITS, tearing both down. `mix mob.connect` (with IEx)
  connects the cluster but IEx itself CRASHES on `IEx.Broker` under Elixir
  1.20.0-rc.5. **Working pattern this session:** let `mob.connect` establish the
  forward, then keep `adb forward tcp:9100 tcp:9100` alive manually, then run a
  fresh control node: `elixir --name probe@127.0.0.1 --cookie mob_secret
  script.exs`. The script does `Node.set_cookie/Node.connect(target)` then
  `:erpc.call(target, Code, :eval_string, [code_string])` — the code STRING runs
  ON the device (all :mob_nif/Mob/Minutemodem modules resident). For NIFs that
  deliver async to the caller pid, the eval string must spawn+call+receive and
  send the result back to the parent. DO NOT use anonymous-fun :erpc (`:undef`,
  closure not on device). DO NOT `iex --remsh` into the device (sliced OTP lacks
  iex.app).
- Verify reachability with a one-liner before the full probe:
  `elixir --name t@127.0.0.1 --cookie mob_secret -e
  'IO.puts(Node.connect(:"minutemodem_mobile_android_19080e11@127.0.0.1"))'`
  — must print `true`. If `false`, the adb forward or epmd registration was
  torn down (re-add the forward).
- `epmd -names` shows the registered device node + port; `nc -z 127.0.0.1 9100`
  confirms the forward is open.

---

## KEY FACTS / REFERENCES

**CP2102 (from FT8CN `Cp21xxSerialDriver.java`, encoded in
`lib/minutemodem_mobile/rig/cp2102.ex`):** DigiRig serial = VID 0x10C4 / PID
0xEA60; audio = CM108; PTT = RTS. REQTYPE host→device 0x41, device→host 0xC1.
Requests: IFC_ENABLE 0x00 (UART_ENABLE value 0x0001), SET_LINE_CTL 0x03,
SET_MHS 0x07 (RTS_ENABLE 0x202 / RTS_DISABLE 0x200 / DTR_ENABLE 0x101 /
DTR_DISABLE 0x100), GET_MDMSTS 0x08 (CTS 0x10/DSR 0x20/RI 0x40/CD 0x80),
SET_BAUDRATE 0x1E (value 0, index port, DATA = 4-byte LE baud). Value-only
requests carry the arg in wValue with no data phase; SET_BAUDRATE needs the
4-byte data buffer; GET_MDMSTS is device→host with a 1-byte read buffer.

**The control_transfer message shape:**
`{:peripheral, :vendor_usb, :control_result, session, %{result: n, data: bin}}`
— `result` is the controlTransfer return (bytes transferred / negative on
error; 0 = ack with no data phase = normal success for value-only requests),
`data` is the read bytes (empty for host→device).

**Audio device types:** USB_DEVICE=11, USB_HEADSET=22 (CM108 DigiRig is THIS,
not 11 — filter on the semantic `is_usb` flag, not a type constant),
BLE_HEADSET=26, BLE_SPEAKER=27. AudioRecord.read negatives: ERROR=-1,
ERROR_BAD_VALUE=-2, ERROR_INVALID_OPERATION=-3, ERROR_DEAD_OBJECT=-6.
MediaRecorder.AudioSource.UNPROCESSED=9.

**Key files:**
- Kotlin bridge: `android/app/src/main/java/com/example/minutemodem_mobile/MobBridge.kt`
  (VendorUsb block + PCM bridge block + the new vendor_usb_control_transfer
  method + nativeDeliverVendorUsbControlResult external).
- JNI thunks: `android/app/src/main/jni/beam_jni.c` (name-mangled thunks +
  local forward-decls for audio_pcm and vendor_usb_control_result, so the app
  build needs no deps/mob/mob_beam.h edit).
- Native NIF (zig): `deps/mob/android/jni/mob_nif.zig` (~5600 lines; nif_funcs[]
  table, Bridge struct of cached JMethodIDs, the vendor_usb + audio_pcm +
  control_transfer NIFs and deliveries).
- BEAM NIF stubs: `deps/mob/src/mob_nif.erl` (THREE places per NIF: -export,
  -nifs, stub body).
- Elixir wrappers: `deps/mob/lib/mob/vendor_usb.ex` (Mob.VendorUsb, now with
  control_transfer/7), `lib/minutemodem_mobile/audio_pcm.ex`
  (MinutemodemMobile.AudioPcm).
- CP2102 protocol: `lib/minutemodem_mobile/rig/cp2102.ex`.
- Rig stub (to be replaced): `lib/minutemodem_mobile/rig/stub_control.ex`
  (implements `Minutewave.Rig.Control.Behaviour`, registered under
  `Minutewave.Rig.InstanceRegistry` as `{rig_id, :control}`).
- FT8CN reference clone: `/Users/mac.w/src/FT8CN` (MIT, Java).
- milwave-rs pinned in `native/phy_modem`.

**Skills active for this work:** `zabbix-tooling` (AP&T, unrelated), `hrc`
(compress large logs before reading — `hrc FILE`, `hrc run -- CMD`, `hrc get
HASH`; skip for Elixir source), `caveman` (token-saver).

---

## SESSION HYGIENE

- Scratch convention: edit scripts `.zig_edit*.py` / `.erl_edit.py` /
  `.kt_edit.py` / `.jni_edit.py` / `.ex_edit.py`, probes `.probe_*.exs`, grep
  dumps `.vbw.txt`, commit msgs `.cm.txt`. Clean ALL before committing; verify
  host = L21360 first.
- At session end, a `mix mob.connect` tunnel and an `adb forward tcp:9100` may
  be left holding the device connection (this session: in window `@1`). Fine to
  leave; note they're there.
