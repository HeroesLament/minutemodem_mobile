defmodule MinutemodemMobile.ALE.LqaStore do
  @moduledoc """
  `Minutewave.ALE.LQA.Store` implementation backed by the `lqa_soundings`
  Ecto table.

  The library's `Minutewave.ALE.LQA` engine owns the scoring and ranking math
  but not persistence — it fetches history through this behaviour. We store
  the composite score in `extra["lqa_score"]` (the convention the schema and
  the library's callbacks agree on) and read it back here.

  ## Scoping

  Observations are stored per-network (`lqa_soundings.network_id`). The single
  DigiRig deployment has exactly one active network at a time, so the store
  scopes every query to `Networks.active/0`. The behaviour's `rig_id` argument
  is accepted for contract compatibility but not used for scoping (one rig).
  When no network is active there is no history, so queries return empty.

  ## Configuration

      config :minutewave, lqa_store: MinutemodemMobile.ALE.LqaStore

  Fed by `MinutemodemMobile.ALE.LqaRecorder`, which subscribes to the rig's
  event bus and persists `{:ale, {:lqa_observation, _}}` observations.
  """

  @behaviour Minutewave.ALE.LQA.Store

  import Ecto.Query

  alias MinutemodemMobile.Networks
  alias MinutemodemMobile.Repo
  alias MinutemodemMobile.Schemas.LqaSounding

  @default_hours 24

  @impl Minutewave.ALE.LQA.Store
  def recent_observations(_rig_id, dest_addr, freq_list, opts) do
    case Networks.active() do
      nil ->
        []

      net ->
        cutoff = cutoff(opts)

        from(o in LqaSounding,
          join: c in assoc(o, :callsign),
          where:
            o.network_id == ^net.id and c.addr == ^dest_addr and
              o.freq_hz in ^freq_list and o.timestamp >= ^cutoff,
          select: %{freq_hz: o.freq_hz, timestamp: o.timestamp, extra: o.extra}
        )
        |> Repo.all()
        |> Enum.map(fn row ->
          %{freq_hz: row.freq_hz, timestamp: row.timestamp, lqa_score: score_of(row.extra)}
        end)
    end
  end

  @impl Minutewave.ALE.LQA.Store
  def last_heard_per_freq(_rig_id, freq_list, opts) do
    case Networks.active() do
      nil ->
        %{}

      net ->
        cutoff = cutoff(opts)

        from(o in LqaSounding,
          where:
            o.network_id == ^net.id and o.freq_hz in ^freq_list and
              o.timestamp >= ^cutoff,
          group_by: o.freq_hz,
          select: {o.freq_hz, type(max(o.timestamp), :utc_datetime_usec)}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp cutoff(opts) do
    hours = Keyword.get(opts, :hours, @default_hours)
    DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
  end

  defp score_of(extra) when is_map(extra), do: Map.get(extra, "lqa_score")
  defp score_of(_), do: nil
end
