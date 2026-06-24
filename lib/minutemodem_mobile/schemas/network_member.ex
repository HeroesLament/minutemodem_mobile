defmodule MinutemodemMobile.Schemas.NetworkMember do
  @moduledoc """
  Join between a global `Callsign` and a `Network`: which stations belong
  to which network, with an optional per-network `alias`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias MinutemodemMobile.Schemas.{Network, Callsign}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "network_members" do
    belongs_to :network, Network
    belongs_to :callsign, Callsign
    field :alias, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:network_id, :callsign_id, :alias])
    |> validate_required([:network_id, :callsign_id])
    |> foreign_key_constraint(:network_id)
    |> foreign_key_constraint(:callsign_id)
    |> unique_constraint([:network_id, :callsign_id])
  end
end
