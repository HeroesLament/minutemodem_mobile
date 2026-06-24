defmodule MinutemodemMobile.Schemas.Callsign do
  @moduledoc """
  Global directory entry for a known or heard station. A callsign exists
  once regardless of which network heard it; per-network membership is
  expressed via `MinutemodemMobile.Schemas.NetworkMember`.

  Mirrors the desktop MinuteModemCore.Persistence.Schemas.Callsign shape
  so address-book data is portable between station types.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias MinutemodemMobile.Schemas.{NetworkMember, LqaSounding}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_sources ~w(manual sounding inbound_call imported)

  schema "callsigns" do
    field :addr, :integer
    field :name, :string
    field :callsign, :string
    field :source, :string

    field :first_heard, :utc_datetime_usec
    field :last_heard, :utc_datetime_usec
    field :heard_count, :integer, default: 0

    field :notes, :string
    field :protocol_config, :map, default: %{}

    has_many :memberships, NetworkMember
    has_many :lqa_soundings, LqaSounding

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(callsign, attrs) do
    callsign
    |> cast(attrs, [:addr, :name, :callsign, :source, :first_heard, :last_heard, :heard_count, :notes, :protocol_config])
    |> validate_required([:addr, :source])
    |> validate_inclusion(:source, @valid_sources)
    |> validate_number(:addr, greater_than_or_equal_to: 0, less_than: 0x10000)
    |> unique_constraint(:addr)
  end
end
