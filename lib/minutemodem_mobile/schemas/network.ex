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

  alias MinutemodemMobile.Schemas.{NetworkMember, LqaSounding, Channel}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_types ~w(ale data)

  # ALE generations. Only 4G (188-141D) has a working link FSM today; 3G/2G are
  # reserved so a net can be defined for them ahead of implementation.
  @valid_generations ~w(4g 3g 2g)
  @default_generation "4g"

  schema "networks" do
    field :name, :string
    field :type, :string
    field :active, :boolean, default: false
    field :params, :map, default: %{}

    has_many :members, NetworkMember
    has_many :lqa_soundings, LqaSounding
    has_many :channels, Channel, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(network, attrs) do
    network
    |> cast(attrs, [:name, :type, :active, :params])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @valid_types)
    |> default_generation()
    |> validate_generation()
    |> unique_constraint(:name)
  end

  @doc """
  Valid ALE generations (`"4g" | "3g" | "2g"`). Only 4G is operational; 3G/2G
  are reserved.
  """
  def valid_generations, do: @valid_generations

  @doc "Default ALE generation for new networks (`\"4g\"`)."
  def default_generation, do: @default_generation

  # Ensure ALE networks carry a generation in params (default 4g). Leaves data
  # networks untouched — generation is meaningless for direct 110D data modes.
  defp default_generation(changeset) do
    type = get_field(changeset, :type)

    if type == "ale" do
      params = get_field(changeset, :params) || %{}

      if Map.has_key?(params, "generation") do
        changeset
      else
        put_change(changeset, :params, Map.put(params, "generation", @default_generation))
      end
    else
      changeset
    end
  end

  # Reject an unknown generation value for ALE networks. A missing key has
  # already been defaulted above; this guards against a bad explicit value.
  defp validate_generation(changeset) do
    type = get_field(changeset, :type)
    params = get_field(changeset, :params) || %{}
    gen = Map.get(params, "generation")

    cond do
      type != "ale" -> changeset
      gen in @valid_generations -> changeset
      true -> add_error(changeset, :params, "invalid ALE generation: #{inspect(gen)}")
    end
  end
end
