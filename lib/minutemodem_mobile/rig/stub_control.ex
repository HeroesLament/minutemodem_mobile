defmodule MinutemodemMobile.Rig.StubControl do
  @moduledoc """
  In-memory rig control for testing without real CAT hardware.

  Stores frequency, mode, PTT, and TX ownership in process state. No
  actual radio is contacted. Useful for protocol-level loopback tests
  where the rig doesn\'t need to physically tune anything.

  One process per rig, registered under `Minutewave.Rig.InstanceRegistry`
  with key `{rig_id, :control}`.
  """

  @behaviour Minutewave.Rig.Control.Behaviour

  use GenServer
  require Logger

  defstruct [
    :rig_id,
    frequency: 14_100_000,   # 20m default
    mode: :usb,
    ptt: :off,
    tx_owner: nil
  ]

  # ----------------------------------------------------------------------------
  # Lifecycle
  # ----------------------------------------------------------------------------

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  defp via(rig_id) do
    {:via, Registry, {Minutewave.Rig.InstanceRegistry, {rig_id, :control}}}
  end

  # ----------------------------------------------------------------------------
  # Behaviour callbacks
  # ----------------------------------------------------------------------------

  @impl Minutewave.Rig.Control.Behaviour
  def acquire_tx(rig_id, tag), do: GenServer.call(via(rig_id), {:acquire_tx, tag})

  @impl Minutewave.Rig.Control.Behaviour
  def release_tx(rig_id, _tag), do: GenServer.call(via(rig_id), :release_tx)

  @impl Minutewave.Rig.Control.Behaviour
  def get_frequency(rig_id), do: GenServer.call(via(rig_id), :get_frequency)

  @impl Minutewave.Rig.Control.Behaviour
  def set_frequency(rig_id, hz), do: GenServer.call(via(rig_id), {:set_frequency, hz})

  @impl Minutewave.Rig.Control.Behaviour
  def get_mode(rig_id), do: GenServer.call(via(rig_id), :get_mode)

  @impl Minutewave.Rig.Control.Behaviour
  def set_mode(rig_id, mode), do: GenServer.call(via(rig_id), {:set_mode, mode})

  @impl Minutewave.Rig.Control.Behaviour
  def status(rig_id), do: GenServer.call(via(rig_id), :status)

  @impl Minutewave.Rig.Control.Behaviour
  def capabilities do
    %{
      simulator: true,
      reports_signal_level: false,
      vfo_count: 1,
      supported_modes: [:usb, :lsb, :am, :fm, :cw, :digital]
    }
  end

  # ----------------------------------------------------------------------------
  # GenServer
  # ----------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    state = %__MODULE__{rig_id: rig_id}
    Logger.info("[Rig.StubControl] Started for #{inspect(rig_id)}")
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:acquire_tx, tag}, _from, %{tx_owner: nil} = state) do
    {:reply, :ok, %{state | tx_owner: tag}}
  end

  def handle_call({:acquire_tx, _tag}, _from, %{tx_owner: current} = state) do
    {:reply, {:error, {:busy, current}}, state}
  end

  def handle_call(:release_tx, _from, state),
    do: {:reply, :ok, %{state | tx_owner: nil}}

  def handle_call(:get_frequency, _from, state),
    do: {:reply, {:ok, state.frequency}, state}

  def handle_call({:set_frequency, hz}, _from, state),
    do: {:reply, :ok, %{state | frequency: hz}}

  def handle_call(:get_mode, _from, state),
    do: {:reply, {:ok, state.mode}, state}

  def handle_call({:set_mode, mode}, _from, state),
    do: {:reply, :ok, %{state | mode: mode}}

  def handle_call(:status, _from, state) do
    reply = %{
      frequency: state.frequency,
      mode: state.mode,
      tx_active?: state.ptt == :on,
      tx_owner: state.tx_owner
    }
    {:reply, {:ok, reply}, state}
  end
end
