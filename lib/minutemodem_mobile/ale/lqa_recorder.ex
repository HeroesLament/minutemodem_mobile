defmodule MinutemodemMobile.ALE.LqaRecorder do
  @moduledoc """
  Persists ALE link-quality observations into the `lqa_soundings` table.

  This is the *inbound* half of the LQA seam. `Minutewave.ALE.LQA` scores each
  decoded frame and broadcasts `{:ale, {:lqa_observation, map}}` on the rig's
  event bus (`Minutewave.Modem.Events`); this GenServer subscribes to that bus
  and writes a row per observation, upserting the source station into the
  `callsigns` directory. `MinutemodemMobile.ALE.LqaStore` reads the rows back
  for ranking and for the Link Quality view.

  ## Scoping

  Rows are scoped to the currently active network (`Networks.active/0`),
  resolved at insert time. If no network is active the observation is dropped
  (there is nowhere to file it, and `network_id` is non-null).

  ## Robustness

  A transient DB error while inserting must not tear down the subscription, so
  persistence is wrapped: a failure is logged and the observation is dropped.
  The bus monitors this process, so on any crash+restart we re-subscribe.

  Only `:rx`/`:tx` decode observations are persisted. `{:ale, {:sounding_made,
  _}}` (our own transmitted sounding) carries no remote station or score and is
  intentionally ignored here.
  """

  use GenServer
  require Logger

  alias MinutemodemMobile.LQAPolicy
  alias MinutemodemMobile.Networks
  alias MinutemodemMobile.Repo
  alias MinutemodemMobile.Schemas.{Callsign, LqaSounding}
  alias Minutewave.Modem.Events

  @valid_frame_types ~w(sounding call response data terminate)
  @retry_ms 500

  # -- lifecycle -------------------------------------------------------------

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {Minutewave.Rig.InstanceRegistry, {rig_id, :lqa_recorder}}}
  end

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    Logger.metadata(rig: String.slice(to_string(rig_id), 0, 8))
    {:ok, %{rig_id: rig_id}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    subscribe_or_retry(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    subscribe_or_retry(state)
    {:noreply, state}
  end

  # Received a scored decode observation — persist it.
  def handle_info({:ale, {:lqa_observation, obs}}, state) do
    persist(obs)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- subscription ----------------------------------------------------------

  defp subscribe_or_retry(state) do
    case safe_subscribe(state.rig_id) do
      :ok ->
        Logger.debug("[LqaRecorder] subscribed to modem events")

      :error ->
        Process.send_after(self(), :retry_subscribe, @retry_ms)
    end
  end

  defp safe_subscribe(rig_id) do
    Events.subscribe(rig_id, self(), filter: :all)
    :ok
  catch
    :exit, _ -> :error
  end

  # -- persistence -----------------------------------------------------------

  defp persist(%{source_addr: addr, freq_hz: freq} = obs)
       when is_integer(addr) and is_integer(freq) do
    case Networks.active() do
      nil ->
        Logger.debug("[LqaRecorder] no active network; dropping observation")

      net ->
        flags = LQAPolicy.flags_for(net)

        if record?(flags, obs[:direction]) do
          with {:ok, callsign} <- upsert_callsign(addr, obs),
               {:ok, _row} <- insert_sounding(net, callsign, obs) do
            :ok
          else
            {:error, reason} ->
              Logger.warning("[LqaRecorder] persist failed: #{inspect(reason)}")
          end
        else
          Logger.debug(
            "[LqaRecorder] mode #{LQAPolicy.mode(net)} drops #{inspect(obs[:direction])} observation"
          )
        end
    end
  rescue
    e -> Logger.warning("[LqaRecorder] persist raised: #{inspect(e)}")
  catch
    :exit, reason -> Logger.warning("[LqaRecorder] persist exited: #{inspect(reason)}")
  end

  defp persist(_obs), do: :ok

  defp insert_sounding(net, callsign, obs) do
    attrs = %{
      network_id: net.id,
      callsign_id: callsign.id,
      timestamp: DateTime.utc_now(),
      freq_hz: obs.freq_hz,
      snr_db: obs[:snr_db],
      direction: normalize_direction(obs[:direction]),
      frame_type: normalize_frame_type(obs[:frame_type]),
      extra: %{"lqa_score" => obs[:lqa_score]}
    }

    %LqaSounding{}
    |> LqaSounding.changeset(attrs)
    |> Repo.insert()
  end

  # Get-or-create the station in the directory, bumping last_heard/heard_count.
  defp upsert_callsign(addr, obs) do
    now = DateTime.utc_now()

    case Repo.get_by(Callsign, addr: addr) do
      nil ->
        %Callsign{}
        |> Callsign.changeset(%{
          addr: addr,
          source: callsign_source(obs),
          first_heard: now,
          last_heard: now,
          heard_count: 1
        })
        |> Repo.insert()

      %Callsign{} = cs ->
        cs
        |> Callsign.changeset(%{last_heard: now, heard_count: (cs.heard_count || 0) + 1})
        |> Repo.update()
    end
  end

  defp callsign_source(%{frame_type: "sounding"}), do: "sounding"
  defp callsign_source(_), do: "inbound_call"

  defp normalize_direction(dir) when dir in [:rx, :tx], do: to_string(dir)
  defp normalize_direction(dir) when dir in ["rx", "tx"], do: dir
  defp normalize_direction(_), do: nil

  defp normalize_frame_type(ft) when ft in @valid_frame_types, do: ft
  defp normalize_frame_type(_), do: "data"

  # Whether the active net's LQA mode records an observation of this direction.
  # `:tx` needs record_tx?; everything else (`:rx` / unknown) needs record_rx?.
  defp record?(flags, :tx), do: flags.record_tx?
  defp record?(flags, "tx"), do: flags.record_tx?
  defp record?(flags, _rx_or_unknown), do: flags.record_rx?
end
