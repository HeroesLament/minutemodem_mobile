defmodule MinutemodemMobile.ShellScreen do
  @moduledoc """
  Root screen hosting a bottom TabBar (CONFIG / NETWORK). Mob 0.7.5's
  framework-level tab_bar/drawer nav is not wired through the render path,
  but the native renderer DOES handle a `tab_bar` node directly, so we drive
  the tab bar ourselves: this screen owns all state + events for both tabs
  and renders each tab body via ConfigScreen.render/1 and
  NetworkScreen.render/1 (which are pure functions of assigns).
  """
  use Mob.Screen

  alias MinutemodemMobile.{Networks, ConfigScreen, NetworkScreen}

  def mount(_params, _session, socket) do
    {:ok, load(socket, active_tab: "config", status: nil)}
  end

  # Load all state both tab bodies need: Config (station/networks/audio) and
  # Network (active net + params).
  defp load(socket, extra) do
    networks = Networks.list()
    active = Enum.find(networks, & &1.active)

    socket
    |> Mob.Socket.assign(
      station: Mob.State.get(:station_name, ""),
      audio_backend: audio_backend_name(),
      networks: networks,
      active_name: active && active.name,
      active_type: active && active.type,
      net: active,
      params: (active && active.params) || %{}
    )
    |> Mob.Socket.assign(extra)
  end

  defp audio_backend_name do
    case Application.get_env(:minutewave, :audio_backend) do
      nil -> "NONE"
      mod -> mod |> Module.split() |> List.last() |> String.upcase()
    end
  end

  def render(assigns) do
    ~MOB"""
    <Drawer
      active={assigns.active_tab}
      tabs={[
        %{id: "config", label: "CONFIG", icon: "settings"},
        %{id: "network", label: "NETWORK", icon: "list"}
      ]}
      on_tab_select={{self(), :tab_selected}}
    >
      {ConfigScreen.render(assigns)}
      {NetworkScreen.render(assigns)}
    </Drawer>
    """
  end

  # Tab switching
  def handle_info({:change, :tab_selected, tab_id}, socket) do
    {:noreply, Mob.Socket.assign(socket, active_tab: tab_id)}
  end

  # Config tab events
  def handle_info({:change, :station_changed, value}, socket) do
    Mob.State.put(:station_name, value)
    {:noreply, Mob.Socket.assign(socket, station: value)}
  end

  def handle_info({:tap, {:activate, name}}, socket) do
    net = Enum.find(socket.assigns.networks, &(&1.name == name))

    case net && Networks.activate(net.id) do
      {:ok, _} ->
        {:noreply, load(socket, status: "ACTIVATED " <> name)}

      _ ->
        {:noreply, Mob.Socket.assign(socket, status: "ACTIVATE FAILED")}
    end
  end

  def handle_info({:tap, :new_network}, socket) do
    name = Networks.next_default_name()

    case Networks.create(%{name: name, type: "ale"}) do
      {:ok, _} ->
        {:noreply, load(socket, status: "CREATED " <> name)}

      {:error, _cs} ->
        {:noreply, Mob.Socket.assign(socket, status: "CREATE FAILED")}
    end
  end

  # Network tab events
  def handle_info({:change, {:param_change, key}, value}, socket) do
    case socket.assigns.net do
      nil ->
        {:noreply, socket}

      net ->
        case Networks.update_params(net, %{key => value}) do
          {:ok, updated} ->
            {:noreply, Mob.Socket.assign(socket, net: updated, params: updated.params, status: "SAVED " <> String.upcase(key))}

          {:error, _cs} ->
            {:noreply, Mob.Socket.assign(socket, status: "SAVE FAILED")}
        end
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
