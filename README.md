# MinuteModem

**The phone *is* the modem.** MinuteModem turns an ordinary Android phone into a
self-contained HF radio data terminal — automatic link establishment, a
software modem, and rig control, all running on-device.

No laptop, no separate TNC, no sound-card app chain. A phone, a
[DigiRig](https://digirig.net/) (or compatible audio+CAT interface) over USB-C
OTG, and a radio.

> **Status: alpha / under active development.** MinuteModem is being field-tested
> with a small group of operators. Expect rough edges. See
> [Project status](#project-status).

---

## What it does

MinuteModem implements a modern HF automatic-link-establishment stack and drives
the radio end-to-end from the handset:

- **Automatic Link Establishment (ALE)** following MIL-STD-188-141D — 2G, 3G,
  and 4G/Wideband ALE (WALE) waveforms, scanning, sounding, and linking.
- **Software modem** — MIL-STD-188-110D serial-tone DSP runs on-device on the
  BEAM (via the [`minutewave`](https://github.com/HeroesLament/minutewave_ex)
  engine), so the phone both hears and keys the radio.
- **Link Quality Analysis (LQA)** — a full LQA engine with per-network policy
  (record / report / beacon) and a station-wide EMCON transmit inhibit.
- **ALE Text Chat** — send and receive free-text messages once a link is
  established, with multi-PDU reassembly.
- **Disciplined time** — GNSS time sync feeds the ALE time-of-day clock, with a
  battery-aware duty cycle.
- **Rig control** — CAT over USB via [Hamlib](https://hamlib.github.io/) (tested
  against the Icom IC-705, with Hamlib's full model list available), plus direct
  CP2102 serial control and PTT-via-RTS for DigiRig-class interfaces.
- **Operator workflow** — networks, channels, and contacts management; a linking
  console; link-protection controls; and live spectrum/telemetry views.

## How it works

MinuteModem is an [Elixir](https://elixir-lang.org/) application that runs a full
BEAM (Erlang VM) *on the phone*, packaged as a native Android app by the
[Mob](https://hex.pm/packages/mob) framework. The signal-processing and ALE
protocol work happen in Elixir and native code rather than in the cloud.

```
┌─────────────────────────────────────────────┐
│  Android app (Mob)                           │
│                                              │
│   Elixir / BEAM        ← ALE, LQA, modem,    │
│    │                     UI, persistence      │
│    │  NIFs (Zig + Rust)                       │
│    ├── phy_modem       ← 110D DSP             │
│    └── hamlib_nif      ← CAT control          │
│    │                                          │
│   Kotlin / JNI         ← USB audio (CM108),   │
│                          USB serial (CP2102)  │
└───────────────┬─────────────────────────────┘
                │ USB-C OTG
        DigiRig (audio + CAT) ── Radio
```

Real-time PCM audio is pinned to the USB codec and streamed
Kotlin → JNI → Zig → BEAM; rig control and PTT go out over USB serial. Native
NIFs are cross-compiled for `arm64-v8a` and statically linked into the app's
BEAM at build time.

## Hardware

- An **arm64 Android phone** (Android 9 / API 28 or newer).
- A **DigiRig** or compatible USB interface exposing a CM108-class audio codec
  and a CP2102 serial port (PTT on RTS), connected via **USB-C OTG**.
- An **HF transceiver**. CAT control is provided through Hamlib; PTT can be
  keyed over the serial line.

## Install

Grab the latest signed APK from the
[**Releases**](https://github.com/HeroesLament/minutemodem_mobile/releases) page
and sideload it (enable "Install unknown apps" for your browser or file manager).
The releases page always carries the most recent test build.

On first launch the app requests microphone (USB audio capture), location (GNSS
time), and notification permissions. Grant these for full functionality.

## Building from source

The toolchain is pinned in [`.tool-versions`](.tool-versions) and read
automatically by [mise](https://mise.jdx.dev) or [asdf](https://asdf-vm.com):

```
erlang 29.0
elixir 1.19.5-otp-28   # must match Mob's device runtime — do not bump casually
java   temurin-17.0.18
zig    0.16.0
```

You'll also need the Android SDK (platform 34, build-tools 34), NDK
`27.2.12479018`, and CMake `3.22.1`.

```sh
mise install                 # or: asdf install
mix deps.get
mix mob.install              # downloads the Android OTP runtime bundles

# Cross-compile the native NIFs (Zig + Rust) and build a debug APK to a device:
mix mob.deploy --android --native

# Or produce a release AAB:
mix mob.release --android
```

> **Note on `mob`:** the vendor-USB control-transfer support (CP2102 PTT) is
> carried as a local patch on top of the published `mob` package. CI applies it
> automatically with quilt (see [`ci/patches/mob/`](ci/patches/mob)); for local
> builds the same patch must be applied to `deps/mob` after `mix deps.get`.

### Continuous integration

A [Concourse](https://concourse-ci.org/) pipeline builds the signed APK + AAB in
a reproducible container and publishes it to GitHub Releases. See
[`ci/README.md`](ci/README.md) for the pipeline, the build image, and secret
management.

## Project layout

| Path | Contents |
|------|----------|
| `lib/minutemodem_mobile/` | Elixir application: ALE, LQA, modem manager, rig control, GNSS, UI screens, Ecto schemas |
| `native/` | `phy_modem` (110D DSP) and `hamlib_nif` (CAT) Rust NIF crates |
| `android/` | Mob Android host, Kotlin USB audio/serial layer, JNI glue, `build.zig` |
| `ios/` | iOS host scaffolding |
| `ci/` | Concourse pipeline, build image, and the `mob` quilt patch |
| `priv/repo/migrations/` | SQLite (Ecto) schema migrations |

## Related projects

- [`minutewave_ex`](https://github.com/HeroesLament/minutewave_ex) — the ALE +
  188-110D signal-processing engine MinuteModem is built on.
- [`hamlib_ex`](https://github.com/HeroesLament/hamlib_ex) — Elixir/Rust
  bindings to Hamlib, including the Android cross-build.

## Standards & references

- MIL-STD-188-141D — Automatic Link Establishment (2G / 3G / 4G-WALE)
- MIL-STD-188-110D — HF serial-tone modem waveforms
- [Hamlib](https://hamlib.github.io/) — radio CAT control library

## Project status

The audio receive path is built and hardware-proven on a DigiRig; ALE linking,
LQA, GNSS time discipline, chat, and rig control are implemented and in testing.
The transmit/PTT software stack is complete and loads on-device; end-to-end keyed
transmit is pending final hardware validation. This is pre-1.0 software — APIs,
schemas, and behavior may change between builds.

## License

_A license has not yet been chosen for this repository. Until a `LICENSE` file is
added, all rights are reserved by the authors._

## Disclaimer

MinuteModem is experimental software for use with radio transmitters. You are
responsible for operating within your radio license and local regulations,
including permitted bands, modes, power levels, and station identification.
