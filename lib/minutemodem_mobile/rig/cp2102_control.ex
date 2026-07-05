defmodule MinutemodemMobile.Rig.Cp2102Control do
  @moduledoc """
  `Minutewave.Rig.Control.Behaviour` implementation backed by the DigiRig's
  CP2102 serial line (RTS = PTT), via `MinutemodemMobile.Modem.Manager`.

  Drop-in replacement for `MinutemodemMobile.Rig.StubControl`: same behaviour
  surface, but `acquire_tx/2` and `release_tx/2` key and unkey the
  transmitter on real hardware (CP2102 SET_MHS / RTS), and the Manager
  enforces the half-duplex T/R gate underneath (keying also suppresses the RX
  capture path so the demodulator never sees our own transmission).

  This module is a thin adapter — it holds no state. The Manager owns the
  serial session and the TX-ownership lock; this maps the behaviour calls onto
  it.

  ## TX arbitration vs. the Manager gate

  `acquire_tx/2` is the exclusive lock at the *rig* level: one tag
  (`:data` | `:voice` | `:ale` | `:tune`) holds TX at a time, others get
  `{:error, {:busy, tag}}`. Acquiring keys PTT and closes the RX gate;
  releasing unkeys and reopens it. The *protocol-level* TX/RX arbitration
  (whether to start TX given an active RX) is a separate concern owned by
  `Minutewave.Modem.Arbiter` above this.

  ## CAT (frequency / mode)

  Frequency and mode are currently held in the Manager as in-memory state
  (no radio-specific CAT protocol is wired yet — the DigiRig's serial line is
  used for PTT only at this stage). The behaviour surface is satisfied so the
  existing minutewave rig/modem machinery runs unchanged; real CAT (Yaesu /
  Icom / Kenwood over the same CP2102 UART) is a later layer.

  ## Configuration

      config :minutewave, rig_control: MinutemodemMobile.Rig.Cp2102Control

  (Replaces `MinutemodemMobile.Rig.StubControl`.)
  """

  @behaviour Minutewave.Rig.Control.Behaviour

  alias MinutemodemMobile.Modem.Manager

  @impl Minutewave.Rig.Control.Behaviour
  def acquire_tx(rig_id, tag), do: Manager.acquire_tx(rig_id, tag)

  @impl Minutewave.Rig.Control.Behaviour
  def release_tx(rig_id, tag), do: Manager.release_tx(rig_id, tag)

  @impl Minutewave.Rig.Control.Behaviour
  def get_frequency(rig_id), do: Manager.get_frequency(rig_id)

  @impl Minutewave.Rig.Control.Behaviour
  def set_frequency(rig_id, hz), do: Manager.set_frequency(rig_id, hz)

  @impl Minutewave.Rig.Control.Behaviour
  def get_mode(rig_id), do: Manager.get_mode(rig_id)

  @impl Minutewave.Rig.Control.Behaviour
  def set_mode(rig_id, mode), do: Manager.set_mode(rig_id, mode)

  @impl Minutewave.Rig.Control.Behaviour
  def status(rig_id), do: Manager.rig_status(rig_id)

  @impl Minutewave.Rig.Control.Behaviour
  def capabilities do
    %{
      simulator: false,
      reports_signal_level: false,
      vfo_count: 1,
      supported_modes: [:usb, :lsb, :digital]
    }
  end
end
