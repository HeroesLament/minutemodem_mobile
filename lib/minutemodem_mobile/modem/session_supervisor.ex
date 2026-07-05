defmodule MinutemodemMobile.Modem.SessionSupervisor do
  @moduledoc """
  Supervises the modem stack for a single rig:

    * `MinutemodemMobile.Modem.Manager` — owns the physical AudioPcm + CP2102
      sessions and the half-duplex T/R gate (mechanism).
    * `Minutewave.Modem` subsystem — TxFSM / RxFSM / Arbiter / Events
      (protocol).
    * `MinutemodemMobile.ALE.LqaRecorder` — subscribes to the Events bus and
      persists LQA observations into `lqa_soundings` (feeds the Link Quality
      view and `MinutemodemMobile.ALE.LqaStore`).

  ## Start order and the no-session invariant

  The Manager starts first so it is registered before anything calls it. The
  minutewave `Modem.Supervisor` starts second; RxFSM's `init` calls
  `Minutewave.Audio.subscribe/1`, which (with the USB backend configured)
  routes to `Manager.subscribe/2`. That is safe with **no hardware session
  open** — the Manager simply records the subscriber pid; RX binaries only
  begin flowing once `Manager.start_session/2` has opened the audio stream.

  This means the protocol stack can be supervised and resident from boot,
  while the *hardware* session is started deliberately later (so we never key
  a transmitter or pop a USB permission dialog the user didn't ask for). See
  `MinutemodemMobile.Modem.Manager` for the lifecycle rationale.

  ## Restart strategy

  `:rest_for_one`: if the Manager dies, the protocol FSMs above it are
  restarted too (their audio subscription and any in-flight TX ownership are
  invalidated when the hardware sessions are lost). If a protocol FSM dies,
  the Manager — which holds the hardware — is left alone.

  ## Single rig

  One DigiRig, one rig_id (default `"digirig"`). OTG hubs are not reliably
  supported on Android, so multi-rig is intentionally out of scope.
  """

  use Supervisor

  @default_rig_id "digirig"

  def start_link(opts) do
    rig_id = Keyword.get(opts, :rig_id, @default_rig_id)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :rig_id, rig_id), name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {Minutewave.Rig.InstanceRegistry, {rig_id, :modem_session_supervisor}}}
  end

  @doc "The default rig id for the single-DigiRig deployment."
  def default_rig_id, do: @default_rig_id

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)

    # Waveform/channel parameters threaded into the minutewave Modem subsystem.
    # Sample rate is the CM108 codec's native 48 kHz — milwave-rs does all
    # decimation/matched-filtering internally (sps = 20 at 2400 baud), so both
    # TX and RX FSMs run at the same rate; there is no 9600 special-case and no
    # resampler anywhere on the BEAM side.
    sample_rate = Keyword.get(opts, :sample_rate, 48_000)
    waveform = Keyword.get(opts, :waveform, 1)
    bw_khz = Keyword.get(opts, :bw_khz, 3)
    interleaver = Keyword.get(opts, :interleaver, :short)
    duplex_mode = Keyword.get(opts, :duplex_mode, :half_duplex_tx_master)

    children = [
      # CAT authority — owns the Hamlib.Rig and is the sole caller of the
      # Hamlib API. Independent of the Manager's audio/serial hardware
      # session: it boots `:closed` and idle, opened deliberately later via
      # `HamlibStateMachine.open/1`. Placed first so a Manager crash (which
      # restarts everything below it under :rest_for_one) does NOT tear down
      # an open CAT connection.
      {MinutemodemMobile.Rig.HamlibStateMachine, rig_id: rig_id},

      # Mechanism layer — must be registered before RxFSM subscribes.
      {MinutemodemMobile.Modem.Manager, rig_id: rig_id},

      # Protocol layer (TxFSM/RxFSM/Arbiter/Events).
      %{
        id: {Minutewave.Modem, rig_id},
        start:
          {Minutewave.Modem, :start_link,
           [
             [
               rig_id: rig_id,
               waveform: waveform,
               bw_khz: bw_khz,
               interleaver: interleaver,
               sample_rate: sample_rate,
               duplex_mode: duplex_mode,
               rig_type: "physical"
             ]
           ]},
        type: :supervisor
      },

      # LQA persistence — subscribes to the Events bus (started by the Modem
      # subsystem above, so it must come after it) and files observations into
      # the lqa_soundings table. Last child: a crash here re-subscribes cleanly
      # under :rest_for_one without disturbing the protocol stack.
      {MinutemodemMobile.ALE.LqaRecorder, rig_id: rig_id}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
