import Config

# Minutewave protocol stack delegates DSP calls to this NIF module,
# which links against milwave-rs via the local native/phy_modem crate.
config :minutewave, phy_modem_nif: MinutemodemMobile.Nifs.PhyModem

# Minutewave audio backend: loopback for development/testing.
config :minutewave, audio_backend: MinutemodemMobile.Audio.UsbPcmBackend

# Rig-control backend. HamlibControl = CAT via Hamlib over the android-usb
# serial bridge, PTT via Hamlib (ptt_type=RTS) on the same CP2102. The Manager
# then runs audio-only (it does not open the serial line). To fall back to the
# pre-Hamlib path (Manager owns CP2102, keys RTS itself, freq/mode in-memory),
# set this to MinutemodemMobile.Rig.Cp2102Control.
config :minutewave, rig_control: MinutemodemMobile.Rig.HamlibControl

# Hamlib CAT state machine. Owns the Hamlib.Rig and is the sole caller of the
# Hamlib API (frequency/mode).
#
# On Android the DigiRig's CI-V line hangs off a CP2102, which Hamlib cannot
# reach through a `/dev/tty*` pathname (no filesystem serial node under a
# non-root app). Instead we use the patched libhamlib's *android-usb* serial
# bridge: a `rig_pathname` of the form `"android-usb:<device_id>:<port>"` routes
# Hamlib's serial I/O through the `hlx_android_usb_serial_*` host contract
# (native/hamlib_nif/c_src/android_usb_host.c), which JNI-upcalls the Kotlin
# HamlibUsbSerial CP2102 driver. `device_id: 0` lets that driver discover the
# CP2102 by VID/PID (0x10C4/0xEA60) so we don't need the Android UsbDevice id
# ahead of time.
#
# model 3085 = Icom IC-705. The IC-705's remote CI-V jack defaults to 19200
# baud (Menu > Set > Connectors > CI-V). Rig model will become operator-
# selectable via a scrollable modal later; hardcoded here for the first bring-up.
#
# `ptt_type => "RTS"` makes Hamlib key PTT on the serial port's RTS line — the
# CP2102 RTS that the DigiRig wires to the radio's SEND/PTT. Routed through our
# android-usb bridge's set_rts, this is the same low-latency keying the modem's
# half-duplex T/R gate needs, with Hamlib as the single owner of the line.
config :minutemodem_mobile, MinutemodemMobile.Rig.HamlibStateMachine,
  model: 3085,
  conf: %{
    "rig_pathname" => "android-usb:0:0",
    "serial_speed" => "19200",
    "ptt_type" => "RTS"
  }

# Ecto: register the repo so `mix ecto.*` tasks can find it. At runtime the
# repo is started manually in MinutemodemMobile.App.on_start/0 (Mob's
# start_clean boot doesn't start path-dep applications), and the database
# path is resolved there from MOB_DATA_DIR. This dev-only database path is
# used by `mix ecto.migrate` / `mix ecto.create` on the host.
config :minutemodem_mobile, ecto_repos: [MinutemodemMobile.Repo]

config :minutemodem_mobile, MinutemodemMobile.Repo,
  database: Path.expand("../priv/repo/dev.db", __DIR__),
  pool_size: 1
