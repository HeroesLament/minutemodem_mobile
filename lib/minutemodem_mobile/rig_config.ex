defmodule MinutemodemMobile.RigConfig do
  @moduledoc """
  Context for the singleton CAT/Hamlib config (`Schemas.RigConfig`).

  `get/0` returns the persisted row, creating a default one on first use, so
  callers always have a config. `to_hamlib/1` renders it into the
  `{model, conf}` pair `HamlibStateMachine` consumes.
  """
  import Ecto.Query

  alias MinutemodemMobile.Repo
  alias MinutemodemMobile.Schemas.RigConfig, as: Schema

  @doc "The singleton config, created with defaults if it doesn't exist yet."
  def get do
    case Repo.one(from r in Schema, order_by: [asc: r.inserted_at], limit: 1) do
      nil ->
        {:ok, config} = Repo.insert(Schema.changeset(%Schema{}, %{}))
        config

      config ->
        config
    end
  end

  @doc "Update the singleton config. Returns {:ok, config} | {:error, changeset}."
  def update(attrs) do
    get()
    |> Schema.changeset(attrs)
    |> Repo.update()
  rescue
    e -> {:error, e}
  end

  @doc """
  Render a config into the `{model, conf}` Hamlib expects. `conf` always carries
  `rig_pathname`, `serial_speed`, `ptt_type`, and `civaddr` only when set.
  """
  @spec to_hamlib(Schema.t()) :: {integer(), map()}
  def to_hamlib(%Schema{} = c) do
    conf =
      %{
        "rig_pathname" => c.pathname,
        "serial_speed" => c.serial_speed,
        "ptt_type" => c.ptt_type
      }
      |> maybe_put("civaddr", c.civaddr)

    {c.model, conf}
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, _k, ""), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
