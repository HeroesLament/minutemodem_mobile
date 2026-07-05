defmodule MinutemodemMobile.NetworkIO do
  @moduledoc """
  Import/export a network definition as JSON — the whole thing: top-level
  fields, the `params` map, and the structured channel plan.

  ## Format

      {
        "minutemodem_network": 1,
        "name": "NET-1",
        "type": "ale",
        "params": { "generation": "4g", "self_addr": "1001", ... },
        "channels": [
          {"freq_hz": 7102000, "name": "40m HAIL", "mode": "usb",
           "role": "hailing", "enabled": true, "position": 0},
          ...
        ]
      }

  `minutemodem_network` is a format version for forward-compat. Only `name` is
  strictly required on import; `type` defaults to `"ale"`, `params`/`channels`
  to empty.

  ## Import policy

  Import **creates a new network** and its channels in one transaction. If a
  network with the same `name` already exists, the import is **rejected**
  (`{:error, {:name_exists, name}}`) rather than overwriting or renaming — the
  operator resolves the collision explicitly. Any malformed field (bad type,
  out-of-range frequency, unknown mode/role) rolls the whole import back.
  """
  import Ecto.Query

  alias MinutemodemMobile.{Networks, Channels, Repo}
  alias MinutemodemMobile.Schemas.{Network, Channel}

  @format_version 1

  @doc "Serialize a network (params + channels) to a JSON binary."
  @spec export_json(Network.t()) :: binary()
  def export_json(%Network{} = net) do
    %{
      "minutemodem_network" => @format_version,
      "name" => net.name,
      "type" => net.type,
      "params" => net.params || %{},
      "channels" => net.id |> Channels.list() |> Enum.map(&channel_map/1)
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp channel_map(%Channel{} = c) do
    %{
      "freq_hz" => c.freq_hz,
      "name" => c.name,
      "mode" => c.mode,
      "role" => c.role,
      "enabled" => c.enabled,
      "position" => c.position
    }
  end

  @doc """
  Create a network (and its channels) from a JSON binary. Returns
  `{:ok, network}` or `{:error, reason}` where reason is one of
  `:invalid_json`, `:missing_name`, `{:name_exists, name}`,
  `{:invalid_network, changeset}`, `{:invalid_channel, reason}`.
  """
  @spec import_json(binary()) :: {:ok, Network.t()} | {:error, term()}
  def import_json(json) when is_binary(json) do
    with {:ok, data} <- decode(json),
         {:ok, name} <- fetch_name(data),
         :ok <- ensure_unique(name) do
      insert_network(name, data)
    end
  end

  def import_json(_), do: {:error, :invalid_json}

  # ── internals ───────────────────────────────────────────────────────────

  defp decode(json) do
    case :json.decode(json) do
      map when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp fetch_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :missing_name}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_name(_), do: {:error, :missing_name}

  defp ensure_unique(name) do
    exists? = Repo.exists?(from n in Network, where: n.name == ^name)
    if exists?, do: {:error, {:name_exists, name}}, else: :ok
  end

  defp insert_network(name, data) do
    type = Map.get(data, "type", "ale")
    params = Map.get(data, "params", %{})
    channels = data |> Map.get("channels", []) |> List.wrap()

    Repo.transaction(fn ->
      net =
        case Networks.create(%{"name" => name, "type" => type, "params" => params}) do
          {:ok, net} -> net
          {:error, changeset} -> Repo.rollback({:invalid_network, changeset})
        end

      channels
      |> Enum.with_index()
      |> Enum.each(fn {ch, idx} ->
        case Channels.add(net.id, sanitize_channel(ch, idx)) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback({:invalid_channel, reason})
        end
      end)

      net
    end)
  end

  # Pull only the known channel fields from an untrusted JSON map, defaulting
  # mode/role/enabled and falling back to list order for position.
  defp sanitize_channel(ch, idx) when is_map(ch) do
    %{
      "freq_hz" => ch["freq_hz"],
      "name" => ch["name"],
      "mode" => ch["mode"] || "usb",
      "role" => ch["role"] || "none",
      "enabled" => Map.get(ch, "enabled", true),
      "position" => ch["position"] || idx
    }
  end

  defp sanitize_channel(_ch, _idx), do: %{}
end
