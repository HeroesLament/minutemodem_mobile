defmodule MinutemodemMobile.ALE.Supervisor do
  @moduledoc """
  Supervises the ALE subsystem for a single rig — started deliberately, not on
  boot.

  The ALE stack (`Minutewave.ALE.Link`, `.Receiver`, `.Transmitter`) needs a
  `self_addr` and only makes sense for an active **4G** ALE network, so it is
  not part of the static boot tree. Instead this is a `DynamicSupervisor` that
  the Linking view (or network activation) drives via `start_stack/2` and
  `stop_stack/1`.

  ## Lifecycle

      start_stack(rig_id, self_addr)  # operator opens a 4G net / taps SCAN
      stop_stack(rig_id)              # operator leaves / switches net

  Re-calling `start_stack/2` first tears down any running stack so a changed
  `self_addr` (operator edited the network) takes effect cleanly.

  ## Dependencies

  Requires the `:minutemodem_pg` process-group scope to be running (started in
  `MinutemodemMobile.App.on_start/0`). `Link`/`Transmitter` broadcast ALE
  state changes and events through that scope, and the Linking screen joins
  the `{:minutemodem, :rig, rig_id}` group to receive them. The modem
  `SessionSupervisor` must also be running, since ALE TX routes through
  `Minutewave.Audio.play_tx/4` → the USB backend → the Manager, and ALE RX
  subscribes to the same `Minutewave.Audio` facade.

  The LQA database (`lqa_soundings`) is a plain Ecto table — no process to
  start here. `Minutewave.ALE.LQA` is storage-agnostic: it reads history
  through the configured `Minutewave.ALE.LQA.Store`
  (`MinutemodemMobile.ALE.LqaStore`) and emits observations as events that
  `MinutemodemMobile.ALE.LqaRecorder` (under the modem `SessionSupervisor`)
  persists.
  """

  use DynamicSupervisor

  require Logger

  alias Minutewave.ALE.{Link, Receiver, Transmitter}

  @default_sample_rate 48_000

  def start_link(opts) do
    rig_id = Keyword.get(opts, :rig_id, MinutemodemMobile.Modem.SessionSupervisor.default_rig_id())
    DynamicSupervisor.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {Minutewave.Rig.InstanceRegistry, {rig_id, :ale_supervisor}}}
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start (or restart) the ALE stack for `rig_id` with the given integer
  `self_addr`. Tears down any running stack first so an edited self_addr takes
  effect. Returns `:ok` or `{:error, reason}`.
  """
  def start_stack(rig_id, self_addr) when is_integer(self_addr) do
    stop_stack(rig_id)

    sup = via(rig_id)

    children = [
      {Transmitter, rig_id: rig_id, sample_rate: @default_sample_rate},
      {Receiver, rig_id: rig_id, sample_rate: @default_sample_rate},
      {Link, rig_id: rig_id, self_addr: self_addr}
    ]

    Enum.reduce_while(children, :ok, fn child, _acc ->
      case DynamicSupervisor.start_child(sup, child) do
        {:ok, _pid} ->
          {:cont, :ok}

        {:error, {:already_started, _pid}} ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.error("[ALE.Supervisor] failed to start #{inspect(child)}: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Stop the ALE stack for `rig_id`. Terminates Link/Receiver/Transmitter if
  running. Idempotent — safe to call when nothing is running.
  """
  def stop_stack(rig_id) do
    sup = via(rig_id)

    case Registry.lookup(Minutewave.Rig.InstanceRegistry, {rig_id, :ale_supervisor}) do
      [{_pid, _}] ->
        for {_, child_pid, _, _} <- DynamicSupervisor.which_children(sup) do
          DynamicSupervisor.terminate_child(sup, child_pid)
        end

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Whether the ALE stack is currently running for `rig_id` (Link FSM present).
  """
  def running?(rig_id) do
    case Registry.lookup(Minutewave.Rig.InstanceRegistry, {rig_id, :ale_link}) do
      [{_pid, _}] -> true
      _ -> false
    end
  end
end
