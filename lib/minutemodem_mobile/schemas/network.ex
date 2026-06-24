defmodule MinutemodemMobile.Schemas.Network do
  @moduledoc """
  A named network definition. The modem is mode-exclusive: exactly one
  network is `active` at a time, and its `type` determines whether the
  PHY runs ALE signalling (188-141) with 188-110D follow-on, or direct
  188-110D data modes.

  Per-network parameters (channel/scan list, sounding cadence and link
  timeouts for ALE; fixed frequency + waveform/data-rate/interleaver for
  data) live in the `params` map, edited by the Network view. LQA history
  is scoped to a network via `has_many :lqa_soundings`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias MinutemodemMobile.Schemas.{NetworkMember, LqaSounding}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_types ~w(ale data)

  schema "networks" do
    field :name, :string
    field :type, :string
    field :active, :boolean, default: false
    field :params, :map, default: %{}

    has_many :members, NetworkMember
    has_many :lqa_soundings, LqaSounding

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(network, attrs) do
    network
    |> cast(attrs, [:name, :type, :active, :params])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @valid_types)
    |> unique_constraint(:name)
  end
end
