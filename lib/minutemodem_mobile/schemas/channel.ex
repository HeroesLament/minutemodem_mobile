defmodule MinutemodemMobile.Schemas.Channel do
  @moduledoc """
  A single operating channel within a network — a structured element, not a
  parsed frequency string.

  Each channel carries its frequency, an operator label, a mode, and a `role`.
  Channels are ordered within their network by `position` (the scan / display
  order). The Linking view commands the rig onto a channel (tune + listen) and
  scans across the network's channel set.

  ## Role

  A channel's `role` designates how the net uses it:

    * `"hailing"` — scanned/sounded for link establishment (the calling set).
    * `"traffic"` — reserved for data once a link is up (not scanned).
    * `"none"`    — defined but not designated for either (parked).

  Roles are mutually exclusive. `enabled` is an independent on/off so a channel
  can be excluded from scan/use without deleting it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias MinutemodemMobile.Schemas.Network

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_modes ~w(usb lsb am fm cw digital)
  @valid_roles ~w(hailing traffic none)

  schema "channels" do
    belongs_to :network, Network

    field :freq_hz, :integer
    field :name, :string
    field :mode, :string, default: "usb"
    field :role, :string, default: "none"
    field :enabled, :boolean, default: true
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:network_id, :freq_hz, :name, :mode, :role, :enabled, :position])
    # freq_hz is optional so a blank channel can be added and then filled in;
    # a set frequency is still range-validated, and nil-freq channels are
    # filtered out of scan/tune sets (see Channels).
    |> validate_required([:network_id])
    |> validate_number(:freq_hz, greater_than: 0, less_than: 1_000_000_000)
    |> validate_inclusion(:mode, @valid_modes)
    |> validate_inclusion(:role, @valid_roles)
    |> foreign_key_constraint(:network_id)
  end

  @doc "Valid mode strings (match `Rig.Control.Behaviour` modes)."
  def valid_modes, do: @valid_modes

  @doc "Valid role strings: hailing | traffic | none."
  def valid_roles, do: @valid_roles
end
