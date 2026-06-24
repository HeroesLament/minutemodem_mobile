defmodule MinutemodemMobile.Schemas.LqaSounding do
  @moduledoc """
  Link Quality Analysis sounding record, scoped per-network.

  Signal-quality observations for a callsign over time, used for automatic
  channel selection and link-quality history. Mirrors the desktop
  MinuteModemCore.Persistence.Schemas.LqaSounding shape, with two
  differences for the mobile (self-contained) model:

    * `belongs_to :network` is a real FK (the desktop used a loose
      `net_id` binary_id) — LQA history is per-network.
    * The composite LQA score from `Minutewave.ALE.LQA.score/1` is stored
      in `extra["lqa_score"]`, matching the convention the
      `Minutewave.ALE.LQA.Store` callbacks read back. The typed
      `snr_db`/`ber`/`sinad_db` columns stay null unless a real
      measurement is present (the modem metrics are probe-correlation /
      path-metric-delta / LLR, which live in `extra`).

  ## Direction
  - `rx` — received a frame from this station
  - `tx` — transmitted and got acknowledgment

  ## Frame types
  `sounding` | `call` | `response` | `data` | `terminate`
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias MinutemodemMobile.Schemas.{Network, Callsign}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_directions ~w(rx tx)
  @valid_frame_types ~w(sounding call response data terminate)

  schema "lqa_soundings" do
    belongs_to :network, Network
    belongs_to :callsign, Callsign

    field :timestamp, :utc_datetime_usec
    field :freq_hz, :integer
    field :snr_db, :float
    field :ber, :float
    field :sinad_db, :float

    field :direction, :string
    field :frame_type, :string
    field :extra, :map, default: %{}
  end

  def changeset(sounding, attrs) do
    sounding
    |> cast(attrs, [
      :network_id,
      :callsign_id,
      :timestamp,
      :freq_hz,
      :snr_db,
      :ber,
      :sinad_db,
      :direction,
      :frame_type,
      :extra
    ])
    |> validate_required([:network_id, :callsign_id, :timestamp, :freq_hz])
    |> validate_inclusion(:direction, @valid_directions ++ [nil])
    |> validate_inclusion(:frame_type, @valid_frame_types ++ [nil])
    |> foreign_key_constraint(:network_id)
    |> foreign_key_constraint(:callsign_id)
  end

  @doc "Convenience: the composite LQA score stored in `extra`, or nil."
  def lqa_score(%__MODULE__{extra: extra}) when is_map(extra), do: Map.get(extra, "lqa_score")
  def lqa_score(_), do: nil
end
