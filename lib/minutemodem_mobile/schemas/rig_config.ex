defmodule MinutemodemMobile.Schemas.RigConfig do
  @moduledoc """
  Persisted CAT / Hamlib connection options — a **singleton** (one row) edited in
  the Rig tab's CAT Options subtab and applied to
  `MinutemodemMobile.Rig.HamlibStateMachine`.

  Fields map onto Hamlib's rig selection + conf tokens:

    * `model`        — Hamlib rig model number (e.g. 3010 = IC-706MkII).
    * `transport`    — `"usb"` (the android-usb CP2102 bridge) or `"network"`
      (a host:port, e.g. a remote rigctld). Determines how `pathname` is read.
    * `pathname`     — Hamlib `rig_pathname`: `"android-usb:<dev>:<port>"` for
      USB, or `"host:port"` for network.
    * `serial_speed` — CI-V / serial baud (must match the radio for USB).
    * `civaddr`      — optional Icom CI-V address override (e.g. `"0x4E"`); blank
      means use the model's default.
    * `ptt_type`     — `"RTS"` | `"DTR"` | `"RIG"` (CI-V) | `"NONE"`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @transports ~w(usb network)
  @ptt_types ~w(RTS DTR RIG NONE)

  schema "rig_configs" do
    field :model, :integer, default: 3010
    field :transport, :string, default: "usb"
    field :pathname, :string, default: "android-usb:0:0"
    field :serial_speed, :string, default: "19200"
    field :civaddr, :string
    field :ptt_type, :string, default: "RTS"

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(model transport pathname serial_speed civaddr ptt_type)a

  def changeset(config, attrs) do
    config
    |> cast(attrs, @castable)
    |> update_change(:civaddr, &blank_to_nil/1)
    |> validate_required([:model, :transport, :pathname, :serial_speed, :ptt_type])
    |> validate_number(:model, greater_than: 0)
    |> validate_inclusion(:transport, @transports)
    |> validate_inclusion(:ptt_type, @ptt_types)
    |> validate_format(:serial_speed, ~r/^\d+$/, message: "must be a baud number")
    |> validate_civaddr()
  end

  @doc "Valid transports (`\"usb\" | \"network\"`)."
  def transports, do: @transports

  @doc "Valid PTT types."
  def ptt_types, do: @ptt_types

  # civaddr is optional; when present accept decimal or 0x-hex.
  defp validate_civaddr(changeset) do
    case get_field(changeset, :civaddr) do
      nil -> changeset
      "" -> changeset
      v -> if valid_addr?(v), do: changeset, else: add_error(changeset, :civaddr, "must be decimal or 0xNN")
    end
  end

  defp valid_addr?(v) do
    v = String.trim(v)

    cond do
      String.starts_with?(v, "0x") or String.starts_with?(v, "0X") ->
        match?({_, ""}, Integer.parse(String.slice(v, 2..-1//1), 16))

      true ->
        match?({_, ""}, Integer.parse(v))
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp blank_to_nil(other), do: other
end
