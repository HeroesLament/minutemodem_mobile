defmodule MinutemodemMobile.LinkQuality do
  @moduledoc """
  Read model for the Link Quality view.

  Aggregates persisted `lqa_soundings` (written by
  `MinutemodemMobile.ALE.LqaRecorder`) into the two summaries the UI shows:

    * `channel_summaries/2` — per-frequency quality across a channel set, best
      first. Answers "where should I call?".
    * `station_summaries/1` — per-station recent quality, most-recently-heard
      first. Answers "who have we heard, and how well?".

  All queries are scoped to the active network (`Networks.active/0`) and a
  lookback window (`:hours`, default 24). Scores are the composite LQA score
  from `Minutewave.ALE.LQA.score/1`, stored in `extra["lqa_score"]`.

  This context deliberately does its aggregation in Elixir over a single
  windowed fetch rather than in SQL: the on-device dataset is small, and it
  keeps the code free of adapter-specific JSON-extraction fragments.
  """

  import Ecto.Query

  alias MinutemodemMobile.Networks
  alias MinutemodemMobile.Repo
  alias MinutemodemMobile.Schemas.LqaSounding

  @default_hours 24

  @type channel_summary :: %{
          freq_hz: integer(),
          score: float() | nil,
          last_heard: DateTime.t() | nil,
          count: non_neg_integer()
        }

  @type station_summary :: %{
          addr: integer(),
          name: String.t() | nil,
          score: float() | nil,
          last_score: float() | nil,
          snr_db: float() | nil,
          directions: [String.t()],
          last_heard: DateTime.t(),
          count: non_neg_integer()
        }

  @doc """
  Summarize each frequency in `freqs`, sorted best score first. Channels with
  no observations in the window are included with a `nil` score and sort last.
  """
  @spec channel_summaries([integer()], keyword()) :: [channel_summary()]
  def channel_summaries(freqs, opts \\ []) when is_list(freqs) do
    by_freq =
      opts
      |> recent()
      |> Enum.group_by(& &1.freq_hz)

    freqs
    |> Enum.uniq()
    |> Enum.map(fn freq -> summarize_channel(freq, Map.get(by_freq, freq, [])) end)
    |> Enum.sort_by(fn c -> c.score || -1.0 end, :desc)
  end

  @doc """
  Summarize each station heard in the window, most recently heard first.
  """
  @spec station_summaries(keyword()) :: [station_summary()]
  def station_summaries(opts \\ []) do
    opts
    |> recent()
    |> Enum.group_by(& &1.addr)
    |> Enum.map(fn {addr, rows} -> summarize_station(addr, rows) end)
    |> Enum.sort_by(& &1.last_heard, {:desc, DateTime})
  end

  # -- internal --------------------------------------------------------------

  # One windowed fetch of recent observations for the active network, joined to
  # the callsign directory. Returns plain maps the summaries fold over.
  defp recent(opts) do
    case Networks.active() do
      nil ->
        []

      net ->
        hours = Keyword.get(opts, :hours, @default_hours)
        cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

        from(o in LqaSounding,
          join: c in assoc(o, :callsign),
          where: o.network_id == ^net.id and o.timestamp >= ^cutoff,
          select: %{
            freq_hz: o.freq_hz,
            timestamp: o.timestamp,
            snr_db: o.snr_db,
            direction: o.direction,
            extra: o.extra,
            addr: c.addr,
            name: c.name
          }
        )
        |> Repo.all()
    end
  end

  defp summarize_channel(freq, []) do
    %{freq_hz: freq, score: nil, last_heard: nil, count: 0}
  end

  defp summarize_channel(freq, rows) do
    %{
      freq_hz: freq,
      score: avg_score(rows),
      last_heard: latest_timestamp(rows),
      count: length(rows)
    }
  end

  defp summarize_station(addr, rows) do
    latest = Enum.max_by(rows, & &1.timestamp, DateTime)

    %{
      addr: addr,
      name: latest.name,
      score: avg_score(rows),
      last_score: score_of(latest),
      snr_db: latest.snr_db,
      directions: rows |> Enum.map(& &1.direction) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      last_heard: latest.timestamp,
      count: length(rows)
    }
  end

  defp avg_score(rows) do
    scores = rows |> Enum.map(&score_of/1) |> Enum.reject(&is_nil/1)

    case scores do
      [] -> nil
      _ -> Float.round(Enum.sum(scores) / length(scores), 1)
    end
  end

  defp latest_timestamp(rows) do
    rows |> Enum.map(& &1.timestamp) |> Enum.max(DateTime)
  end

  defp score_of(%{extra: extra}) when is_map(extra), do: Map.get(extra, "lqa_score")
  defp score_of(_), do: nil
end
