# LQA Policy & EMCON — Design Spec

_Status: design, pre-implementation. Anchors the "flesh out Config/Network" work._

Two related controls:

1. **LQA mode** — per-network policy for how this station participates in Link
   Quality Analysis (record / report / beacon). Lives in the **Network** view,
   stored in the network's `params` map (like `generation` / `self_addr`).
2. **EMCON** — a station-wide hard transmit inhibit. Lives in the **Config**
   view, stored in `Mob.State`. Overrides every network's LQA mode.

---

## 1. LQA mode (per-network)

LQA quality flows in two independent directions, so "one-way" is two things:

- **RX (inbound):** we decode a frame, measure our received quality, log "how
  well *we* hear *them*." Passive; needs no cooperation.
- **TX (outbound):** we contribute quality info to the net — report our
  measured SNR in a confirmation (so the peer learns how we hear them) and/or
  sound proactively. This keys the transmitter.

The two one-way modes are mirror images: `rx_only` = listen & log, never
transmit; `tx_only` = beacon/report, don't log. `two_way` = both.

### Modes

| `lqa_mode` | Meaning | record_rx? | report_snr? | record_tx? | tx_permitted? |
|------------|---------|:----------:|:-----------:|:----------:|:-------------:|
| `off`      | LQA disabled entirely | ✗ | ✗ | ✗ | ✗ |
| `rx_only`  | Passive / EMCON-friendly: record inbound, transmit nothing | ✓ | ✗ | ✗ | ✗ |
| `tx_only`  | Beacon: report SNR + sound, don't maintain own table | ✗ | ✓ | ✗ | ✓ |
| `two_way`  | Full: record inbound + report + record peer-reported SNR | ✓ | ✓ | ✓ | ✓ |

The four boolean flags are **derived** from the mode (single source of truth —
no storing inconsistent combos). Sounding is gated by `tx_permitted?` **and**
the separate `sounding_enabled` toggle. `record_tx?` is only meaningful when
`tx_permitted?` (peer SNR only comes back after we transmit a call/response).

Advanced users may later want the raw flags exposed for non-primary combos
(e.g. "log inbound AND beacon, but ignore peer SNR"); defer to an "advanced"
expansion. The three modes above cover the doctrine cases.

### Default

`two_way` for a normal 4G ALE net (the expected full-participation behavior).
Chosen deliberately over `rx_only`: a net member that never contributes SNR
degrades everyone's channel selection. EMCON (below) is the safe escape hatch
when TX must stop, so the default doesn't need to be conservative.

---

## 2. Network `params` keys

All new keys are strings/ints in the existing `params` map. Defaults applied in
`Schemas.Network` changeset (mirroring the `generation` default pattern).

| key | type | default | drives |
|-----|------|---------|--------|
| `lqa_mode` | `"off"\|"rx_only"\|"tx_only"\|"two_way"` | `"two_way"` | mode table above |
| `lqa_lookback_hours` | int | `24` | `LQA.rank_channels(:hours)` — ranking window (see below) |
| `lqa_decay_hours` | int | `4` | `LQA.rank_channels(:decay_hours)` — recency half-life |
| `lqa_channel_select` | `"auto"\|"manual"` | `"manual"` | auto → `ACS.best/2` in the call path |
| `acs_cold_start` | `"config_order"\|"highest_first"\|"lowest_first"` | `"config_order"` | `ACS` ordering when no LQA history |
| `lqa_retention_days` | int | `365` | app-side prune of `lqa_soundings` |
| `sounding_enabled` | bool | `true` | whether to auto-sound (gated by `tx_permitted?`) |
| `sounding_interval` | int (s) | `300` | sounding cadence (already present) |
| `sounding_strategy` | `"round_robin"\|"stalest"` | `"stalest"` | `LQA.stalest_channel` |

A small `MinutemodemMobile.LQAPolicy` module owns: parse `lqa_mode` → the four
flags, and read the numeric opts with defaults. Single place both the recorder
and the Link integration consult.

### Three independent time knobs — do not conflate

These measure different things and are set independently:

- **`lqa_retention_days` (365)** — how long rows physically live in the DB.
  This is for the Link Quality **history / trends** view. Long.
- **`lqa_lookback_hours` (24)** — how far back a **ranking query** reaches when
  choosing a channel to call *now*. Short, because HF propagation is diurnal.
- **`lqa_decay_hours` (4)** — recency half-life *within* the lookback window.

So we keep a year of history but live channel-selection only leans on the last
day. Note: `rank_channels` today is a flat exponential decay over recent hours —
it cannot exploit the full year. The payoff a 365-day store really unlocks is a
future **time-of-day-aware scorer** (this channel at 1400 today vs 1400 on prior
days), which is a `minutewave` enhancement, not just config.

---

## 3. Integration map (what each flag actually pulls)

Split by cost, so we build the cheap wins first.

### Cheap — app-side only, buildable now

- **`record_rx?` / `record_tx?`** — gate in `ALE.LqaRecorder.persist/1`: read
  the active net's `lqa_mode`, drop `:rx` or `:tx` observations that the mode
  disallows. Pure app change.
- **`lqa_lookback_hours` / `lqa_decay_hours`** — thread into
  `LinkQuality.channel_summaries` (switch its simple average to
  `LQA.rank_channels` with the net's opts, for display/selection consistency).
- **`lqa_retention_days`** — a periodic prune (boot + daily via the `schedule`
  pattern) deleting `lqa_soundings` older than N days. New, but self-contained.

### Needs a small library seam

- **`report_snr?`** — `Minutewave.ALE`'s receiver currently **always** encodes
  the measured SNR (`encode_snr_field`) and hands it to `Link.rx_pdu/3`; there's
  no gate. Suppressing it (send the `0` = "unknown" floor instead) needs a
  library-side policy hook — e.g. `config :minutewave, :report_snr` or a
  per-rig policy the Link FSM consults. **Until that lands, `rx_only` can't be
  fully honored on the wire** (we'd still report SNR). Flag this clearly.

### New behavior — app-side, larger

- **`sounding_*` (auto-sound)** — sounding is currently only manual
  (LINKING → SOUND → `Link.sound`). Automatic cadence needs a scheduler that
  calls `Link.sound` every `sounding_interval`, picking the channel via
  `stalest_channel` when `sounding_strategy == "stalest"`, and only while
  `tx_permitted?` and not EMCON.
- **`lqa_channel_select: auto`** — use `Minutewave.ALE.ACS` (Automatic Channel
  Selection, G.5.4.1), not `best_channel` directly. `ACS.best(rig_id, dest_addr)`
  returns `%{freq_hz, basis}` where `basis` is `:lqa` (real history) or
  `:cold_start` (fallback ordering per `acs_cold_start`). **ACS is not started in
  the mobile app yet** — the ALE stack only starts Transmitter/Receiver/Link. So
  this means: add `{ACS, rig_id: …, cold_start: …}` to `ALE.Supervisor`, thread
  the net's lookback/decay as `rank` opts, and surface `basis` in the call UI so
  the operator sees *why* a channel was chosen.

---

## 4. EMCON (station-wide) — Config view

**Emissions control: a hard transmit inhibit.** When on, the station transmits
nothing, for any reason, overriding every network's LQA mode and every TX
control.

### Storage

- `Mob.State` key `:emcon` (bool, default `false`) — persists across restarts.
- Mirrored to `Application.put_env(:minutemodem_mobile, :emcon, bool)` on change
  and at boot, so out-of-process consumers (the Manager) can read it cheaply.

### Enforcement — at the hardware gate, not just the UI

The single choke point every transmission passes through is
`Modem.Manager.handle_call({:acquire_tx, tag}, …)`. EMCON is enforced **there**:
while `:emcon` is set, `acquire_tx` replies `{:error, :emcon}` and never keys
PTT. This makes EMCON a hardware-level guarantee — even a bug in the protocol
stack above cannot key the transmitter. `key_ptt/1` gets a belt-and-suspenders
guard too.

Consequences:
- No soundings, no SNR-bearing confirmations, no calls, no tune — all route
  through `acquire_tx`.
- **Receive is untouched.** Listening/decoding/`record_rx` continue; EMCON
  degrades any LQA mode to its RX portion only. (Effective mode = `rx_only`
  behavior regardless of the per-net setting.)

### UI

- **Config:** a prominent EMCON toggle (red when active). This is a safety
  control — big, unambiguous, hard to hit by accident (confirm-on-enable
  optional).
- **App-wide indicator:** a red "EMCON" banner in the top bar whenever active,
  visible on every tab.
- **LINKING:** disable TX controls (CALL / SOUND / TERMINATE / rig INIT's TX
  side) while EMCON; SCAN (RX) stays available. Show why they're disabled.

---

## 4b. ALE waveform (per-network)

A single per-net waveform applied to **every** transmitted PDU — soundings,
calls, responses, terminates, LQA exchanges. Operator's choice; no per-phase
`auto` split and no cautionary UI. (A local NVIS net has every reason to run
Fast-only — Deep's processing gain buys nothing on strong high-angle paths and
just costs ~16× the airtime. A long-haul net wants Deep. The app can't know
which, so it doesn't guess.)

- `params` key **`ale_waveform`**: `"fast" | "deep"`. Default `"deep"` (safest
  first-contact reach for an unknown net; operators flip local/NVIS nets to
  `fast`).
- Drives **both** Link FSM fields — `data.waveform` (calls/responses/terminates)
  and `data.sounding_waveform` (soundings). The FSM already threads both into
  every frame it assembles (`link.ex` lines 540/632/686/1480/1554/1760 and the
  sounding path), so one value reaches all PDU types.
- **Plumbing** (the one integration point): the app must feed it in. Two existing
  seams — thread it through `ALE.Supervisor.start_stack(rig_id, self_addr, …)`
  into Link init (which sets both fields), and/or populate
  `net.timing_config["sounding_waveform"]` (already read by
  `resolve_sounding_waveform/2`). `start_stack/2` currently passes neither.
- 110D data-waveform params (bandwidth, interleaver, waveform id, data rate) and
  the `data`-type network branch remain **deferred** until 110D traffic work.

---

## 5. UI controls needed

The Network view is currently flat text fields. These want richer primitives —
worth building once and reusing:

- **Toggle row** (on/off) — `sounding_enabled`, and the Config EMCON switch.
- **Segmented selector** — `lqa_mode` (4-way), `lqa_channel_select` (2-way),
  `sounding_strategy` (2-way). Reuse the existing generation-selector pattern.
- **Numeric field w/ validation** — `lqa_lookback_hours`, `lqa_decay_hours`,
  `lqa_retention_days`, `sounding_interval`.

A new **LQA POLICY** group in the ALE branch of `param_fields("ale", …)`,
below the existing generation / self-address / channel-list fields.

---

## 6. Suggested build order

1. **Primitives:** toggle row, segmented selector, numeric field (unblocks
   everything else, reused across Config/Network).
2. **LQA policy — record side (cheap):** `LQAPolicy` module, the `params` keys +
   defaults + validation, the Network LQA-POLICY group, and `record_rx?` /
   `record_tx?` gating in the recorder. Fully honorable today.
3. **EMCON:** `Mob.State` + app-env, the Manager `acquire_tx` gate, Config
   toggle, app-wide banner, LINKING TX-disable. High safety value, self-contained.
4. **`report_snr?` library seam** — coordinate a hook in `minutewave` so
   `rx_only` is honest on the wire.
5. **Auto-sounder + `channel_select: auto`** — the larger Link-integration
   behaviors.
