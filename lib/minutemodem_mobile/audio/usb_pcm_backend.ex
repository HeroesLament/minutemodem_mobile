defmodule MinutemodemMobile.Audio.UsbPcmBackend do
  @moduledoc """
  `Minutewave.Audio.Backend` implementation backed by the DigiRig's CM108
  USB codec, via `MinutemodemMobile.Modem.Manager`.

  This is a thin adapter: it owns no hardware state itself. The Manager holds
  the single pinned `MinutemodemMobile.AudioPcm` duplex stream and the
  half-duplex T/R gate; this module just maps the behaviour's per-`rig_id`
  calls onto Manager calls, capturing the caller pid where the behaviour's
  pub/sub model needs it.

  ## Zero-copy seam

  RX audio is delivered by the Manager to subscribers as
  `{:rx_audio, rig_id, binary}` where `binary` is s16le interleaved PCM —
  forwarded **verbatim** from the AudioPcm bridge, no list conversion. RxFSM
  hands that binary straight to `unified_demod_symbols_bin`.

  TX audio (`play_tx/4`) is likewise an s16le binary (from
  `unified_mod_modulate_bin`); it is passed through to `AudioPcm.write` with
  no per-sample work on the BEAM.

  ## Configuration

      config :minutewave, audio_backend: MinutemodemMobile.Audio.UsbPcmBackend

  (Replaces `MinutemodemMobile.Audio.LoopbackBackend`.)
  """

  @behaviour Minutewave.Audio.Backend

  alias MinutemodemMobile.Modem.Manager

  @impl Minutewave.Audio.Backend
  def subscribe(rig_id) do
    # The behaviour subscribes the *calling* process (RxFSM). Capture it here;
    # the Manager monitors it and delivers {:rx_audio, …} to it directly.
    Manager.subscribe(rig_id, self())
  end

  @impl Minutewave.Audio.Backend
  def unsubscribe(rig_id) do
    Manager.unsubscribe(rig_id, self())
  end

  @impl Minutewave.Audio.Backend
  def play_tx(rig_id, samples, _sample_rate, _opts) do
    # `samples` is s16le binary from unified_mod_modulate_bin (or an iolist
    # thereof). The Manager flattens + enqueues to the AudioTrack and arms the
    # TX drain timer. Sample rate is fixed by the codec (48k); the arg is
    # ignored on this backend.
    Manager.play_tx(rig_id, samples)
    :ok
  end

  @impl Minutewave.Audio.Backend
  def tx_active?(rig_id) do
    Manager.tx_active?(rig_id)
  end

  @impl Minutewave.Audio.Backend
  def capabilities do
    %{
      simnet: false,
      half_duplex: true,
      sample_rates: [48_000],
      max_rigs: 1
    }
  end
end
