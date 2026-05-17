defmodule MinutemodemMobile.Audio.LoopbackBackend do
  @moduledoc """
  In-memory audio loopback for testing minutewave's protocol stack
  without any real audio hardware.

  TX samples submitted via `play_tx/4` are immediately routed to all
  current subscribers as `{:rx_audio, rig_id, samples}` messages. This
  lets us prove end-to-end TX/RX through the FSM pipeline without
  involving USB audio, DigiRig, or anything physical.

  Per-rig state is held in a single GenServer keyed by rig_id, mapping
  rig_id => MapSet of subscriber pids.
  """

  @behaviour Minutewave.Audio.Backend

  use GenServer
  require Logger

  # ----------------------------------------------------------------------------
  # Public API (Minutewave.Audio.Backend callbacks)
  # ----------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl Minutewave.Audio.Backend
  def subscribe(rig_id) do
    GenServer.call(__MODULE__, {:subscribe, rig_id, self()})
  end

  @impl Minutewave.Audio.Backend
  def unsubscribe(rig_id) do
    GenServer.call(__MODULE__, {:unsubscribe, rig_id, self()})
  end

  @impl Minutewave.Audio.Backend
  def play_tx(rig_id, samples, _rate, _opts) do
    GenServer.cast(__MODULE__, {:loop, rig_id, samples})
    :ok
  end

  @impl Minutewave.Audio.Backend
  def tx_active?(_rig_id), do: false

  @impl Minutewave.Audio.Backend
  def capabilities do
    %{
      simnet: true,
      half_duplex: false,
      sample_rates: [9600, 19200, 48000],
      max_rigs: :unlimited
    }
  end

  # ----------------------------------------------------------------------------
  # GenServer
  # ----------------------------------------------------------------------------

  @impl GenServer
  def init(_) do
    # subs is %{rig_id => MapSet.new(pid)}
    {:ok, %{subs: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, rig_id, pid}, _from, state) do
    Process.monitor(pid)
    set = Map.get(state.subs, rig_id, MapSet.new()) |> MapSet.put(pid)
    new_state = put_in(state.subs[rig_id], set)
    Logger.debug("[Audio.Loopback] #{inspect(pid)} subscribed for #{inspect(rig_id)}")
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:unsubscribe, rig_id, pid}, _from, state) do
    set = Map.get(state.subs, rig_id, MapSet.new()) |> MapSet.delete(pid)
    new_state = put_in(state.subs[rig_id], set)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_cast({:loop, rig_id, samples}, state) do
    subscribers = Map.get(state.subs, rig_id, MapSet.new())

    if MapSet.size(subscribers) > 0 do
      Logger.debug("[Audio.Loopback] looping #{length(samples)} samples to #{MapSet.size(subscribers)} subs for #{inspect(rig_id)}")
    end

    Enum.each(subscribers, fn pid ->
      send(pid, {:rx_audio, rig_id, samples})
    end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subs =
      state.subs
      |> Enum.map(fn {rig_id, set} -> {rig_id, MapSet.delete(set, pid)} end)
      |> Map.new()

    {:noreply, %{state | subs: new_subs}}
  end
end
