defmodule MinutemodemMobile.Rig.HamlibControl do
  @moduledoc """
  `Minutewave.Rig.Control.Behaviour` backed by Hamlib for CAT and the
  CP2102/DigiRig for PTT.

  This adapter **composes two authorities** rather than owning rig I/O itself:

    * **CAT** (frequency, mode) → `MinutemodemMobile.Rig.HamlibStateMachine`,
      the `gen_statem` that owns the `Hamlib.Rig` and is the sole caller of the
      Hamlib API.
    * **TX** (`acquire_tx`/`release_tx`) → `MinutemodemMobile.Modem.Manager`,
      which keys PTT over the CP2102 RTS line and enforces the half-duplex T/R
      gate.

  Keeping PTT on the Manager (not Hamlib's `set_ptt`) means RTS has exactly one
  owner, so CAT control and the T/R timing never contend for the line. This is
  a deliberate split: Hamlib is excellent at CAT across rig families, but the
  modem's half-duplex keying needs to stay coupled to the RX-suppression gate
  the Manager already runs.

  ## Selecting this backend

      config :minutewave, rig_control: MinutemodemMobile.Rig.HamlibControl

  (In place of `MinutemodemMobile.Rig.Cp2102Control` or `…StubControl`.)

  ## status/1

  Merges the Manager's TX view (`tx_active?`, `tx_owner`) with the state
  machine's CAT view (`frequency`, `mode`). If CAT is not open, frequency/mode
  fall back to whatever the Manager last held, so the status surface never goes
  blank mid-session.
  """

  @behaviour Minutewave.Rig.Control.Behaviour

  alias MinutemodemMobile.Modem.Manager
  alias MinutemodemMobile.Rig.HamlibStateMachine, as: SM

  # ── TX: Manager owns the T/R gate, Hamlib keys PTT ─────────────────────────
  #
  # The Manager no longer owns the CP2102 under this backend (Hamlib does, for
  # CAT), so PTT is keyed by Hamlib via `ptt_type=RTS` — the same physical RTS
  # line, single-owner. The Manager still runs the half-duplex RX gate. Order:
  # close the gate *before* keying (so we never feed our own carrier to the
  # demod), and unkey *before* reopening the gate on release.

  @impl Minutewave.Rig.Control.Behaviour
  def acquire_tx(rig_id, tag) do
    with :ok <- Manager.acquire_tx(rig_id, tag) do
      case SM.set_ptt(rig_id, true) do
        :ok ->
          :ok

        err ->
          # Keying failed — back out the gate so we don't sit muted with the
          # radio unkeyed (and free the TX-owner lock for the next attempt).
          _ = Manager.release_tx(rig_id, tag)
          err
      end
    end
  end

  @impl Minutewave.Rig.Control.Behaviour
  def release_tx(rig_id, tag) do
    _ = SM.set_ptt(rig_id, false)
    Manager.release_tx(rig_id, tag)
  end

  # ── CAT: the Hamlib state machine ──────────────────────────────────────────

  @impl Minutewave.Rig.Control.Behaviour
  def get_frequency(rig_id), do: SM.get_frequency(rig_id)

  @impl Minutewave.Rig.Control.Behaviour
  def set_frequency(rig_id, hz), do: SM.set_frequency(rig_id, hz)

  @impl Minutewave.Rig.Control.Behaviour
  def get_mode(rig_id), do: SM.get_mode(rig_id)

  @impl Minutewave.Rig.Control.Behaviour
  def set_mode(rig_id, mode), do: SM.set_mode(rig_id, mode)

  # ── status: merge Manager TX view + SM CAT view ────────────────────────────

  @impl Minutewave.Rig.Control.Behaviour
  def status(rig_id) do
    {:ok, mgr} = Manager.rig_status(rig_id)

    case SM.status(rig_id) do
      {:ok, %{state: :open, frequency: freq, mode: mode}} ->
        {:ok, %{mgr | frequency: freq || mgr.frequency, mode: mode || mgr.mode}}

      _ ->
        # CAT not open — Manager's last-held freq/mode stand in.
        {:ok, mgr}
    end
  end

  @impl Minutewave.Rig.Control.Behaviour
  def capabilities do
    %{
      simulator: false,
      reports_signal_level: false,
      vfo_count: 1,
      supported_modes: [:usb, :lsb, :am, :fm, :cw, :digital]
    }
  end
end
