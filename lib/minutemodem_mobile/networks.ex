defmodule MinutemodemMobile.Networks do
  @moduledoc """
  Context for network definitions — the mode-exclusive radio configurations
  created and switched between in the Config screen. Backed by Ecto
  (`MinutemodemMobile.Schemas.Network`), replacing the earlier Mob.State list.

  Exactly one network is active at a time; `activate/1` flips the active flag
  atomically in a transaction so there's never more than one active row.
  """
  import Ecto.Query

  alias MinutemodemMobile.Repo
  alias MinutemodemMobile.Schemas.Network

  @doc "All networks, oldest first (stable list ordering for the UI)."
  def list do
    Repo.all(from n in Network, order_by: [asc: n.inserted_at])
  end

  @doc "The currently active network, or nil."
  def active do
    Repo.one(from n in Network, where: n.active == true, limit: 1)
  end

  @doc "Create a network. `attrs` needs at least :name and :type (\"ale\"/\"data\")."
  def create(attrs) do
    %Network{}
    |> Network.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Make `id` the sole active network. Clears any other active flag first, in a
  single transaction, preserving the modem's one-mode-at-a-time invariant.
  """
  def activate(id) do
    Repo.transaction(fn ->
      Repo.update_all(from(n in Network, where: n.active == true), set: [active: false])

      case Repo.get(Network, id) do
        nil ->
          Repo.rollback(:not_found)

        net ->
          {:ok, updated} =
            net
            |> Network.changeset(%{active: true})
            |> Repo.update()

          updated
      end
    end)
  end

  @doc """
  Merge `new_params` into a network's params map and persist. Returns
  {:ok, network} or {:error, changeset}.
  """
  def update_params(%Network{} = net, new_params) when is_map(new_params) do
    merged = Map.merge(net.params || %{}, new_params)

    net
    |> Network.changeset(%{params: merged})
    |> Repo.update()
  end

  @doc "Fetch a network by id, or nil."
  def get(id), do: Repo.get(Network, id)

  @doc "Generate a default unique network name like NET-1, NET-2."
  def next_default_name do
    "NET-#{length(list()) + 1}"
  end
end
