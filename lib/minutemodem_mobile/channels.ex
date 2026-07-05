defmodule MinutemodemMobile.Channels do
  @moduledoc """
  Context for a network's operating channels — the structured, per-element
  channel plan edited in the Network view (replacing the old comma-separated
  frequency string in `params`).

  Each channel is a `MinutemodemMobile.Schemas.Channel`: frequency, label, mode,
  a `role` (`"hailing" | "traffic" | "none"`) and an `enabled` flag, ordered
  within its network by `position`.

  The Linking view consumes these: `scan_set/1` returns the enabled hailing
  channels the ALE scanner listens across, and `tunable/1` the enabled channels
  the operator can command the rig onto.
  """
  import Ecto.Query

  alias MinutemodemMobile.Repo
  alias MinutemodemMobile.Schemas.Channel

  @doc "All channels for a network, in scan/display order (position, then age)."
  def list(network_id) do
    Repo.all(
      from c in Channel,
        where: c.network_id == ^network_id,
        order_by: [asc: c.position, asc: c.inserted_at]
    )
  end

  @doc """
  Append a channel to a network. Defaults its `position` after the current last
  so new rows land at the bottom of the list. `attrs` may override any field.
  """
  def add(network_id, attrs \\ %{}) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.put_new("network_id", network_id)
      |> Map.put_new("position", next_position(network_id))

    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
  rescue
    # A raw DB error (e.g. a stale NOT NULL constraint) must not crash the
    # calling screen — surface it as a normal error tuple instead.
    e -> {:error, e}
  end

  @doc "Update a channel by id with `attrs`. Returns {:ok, channel} | {:error, _}."
  def update(id, attrs) do
    case Repo.get(Channel, id) do
      nil -> {:error, :not_found}
      ch -> ch |> Channel.changeset(normalize_keys(attrs)) |> Repo.update()
    end
  rescue
    e -> {:error, e}
  end

  @doc "Delete a channel by id. Returns :ok even if it was already gone."
  def delete(id) do
    case Repo.get(Channel, id) do
      nil -> :ok
      ch -> Repo.delete(ch) |> case(do: ({:ok, _} -> :ok; other -> other))
    end
  end

  @doc "Toggle a channel's `enabled` flag."
  def toggle_enabled(id) do
    case Repo.get(Channel, id) do
      nil -> {:error, :not_found}
      ch -> ch |> Channel.changeset(%{enabled: not ch.enabled}) |> Repo.update()
    end
  end

  @doc "Fetch a channel by id, or nil."
  def get(id), do: Repo.get(Channel, id)

  @doc """
  The scan set: enabled `hailing` channels, in order. This is what the ALE
  scanner listens across for link establishment. Falls back to all enabled
  channels when none are explicitly marked hailing, so a freshly-defined net
  still scans something.
  """
  def scan_set(network_id) do
    hailing =
      Repo.all(
        from c in Channel,
          where:
            c.network_id == ^network_id and c.enabled == true and
              c.role == "hailing" and not is_nil(c.freq_hz),
          order_by: [asc: c.position, asc: c.inserted_at]
      )

    case hailing do
      [] -> enabled(network_id)
      chs -> chs
    end
  end

  @doc "All enabled channels (any role), in order — the set the operator can tune."
  def tunable(network_id), do: enabled(network_id)

  defp enabled(network_id) do
    Repo.all(
      from c in Channel,
        where: c.network_id == ^network_id and c.enabled == true and not is_nil(c.freq_hz),
        order_by: [asc: c.position, asc: c.inserted_at]
    )
  end

  defp next_position(network_id) do
    (Repo.one(from c in Channel, where: c.network_id == ^network_id, select: max(c.position)) || -1) + 1
  end

  # Accept string- or atom-keyed attrs from the UI/callers.
  defp normalize_keys(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
