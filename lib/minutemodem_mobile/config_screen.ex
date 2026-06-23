defmodule MinutemodemMobile.ConfigScreen do
  @moduledoc """
  Station configuration.

  Three sections:

    * STATION — the station name / ALE address, persisted in `Mob.State`
      under `:station_name`.
    * NETWORKS — a list of named network definitions, each `%{name, type}`
      where type is `:ale` or `:data`. Exactly one is active at a time (the
      modem is mode-exclusive); the active network's name is stored under
      `:active_network`. Tapping a network makes it active. "NEW" appends a
      stub network. The chevron will open the Network view (per-network
      parameters) once that screen exists.
    * AUDIO — the active `Minutewave.Audio.Backend` and its capabilities.
      There is no device-enumeration callback on the behaviour yet, so this
      is a read-only readout (LOOPBACK today); a real picker lands when a
      DigiRig backend + `list_devices` seam exist.

  Tactical theme is carried by layout + color tokens rather than font: hard
  bordered `Box` bezels (`corner_radius: 0`), amber data values, a green
  active-state accent, uppercase letter-spaced labels. The mono look is an
  iOS-only enhancement (Android ignores the `font` prop) and is intentionally
  not depended on here.
  """
  use Mob.Screen
  require Logger

  # amber data value / green active accent — base-palette argb, theme-independent
  @amber 0xFFE8C84A
  @green 0xFF33C24A
  @panel 0xFF0A0A0A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A
  @active_bg 0xFF0E1A0E

  @default_networks [
    %{name: "SE-AK-ALE", type: :ale},
    %{name: "60M-DATA", type: :data}
  ]

  # -- Lifecycle ------------------------------------------------------------

  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       station: Mob.State.get(:station_name, ""),
       networks: Mob.State.get(:networks, @default_networks),
       active: Mob.State.get(:active_network, nil),
       audio_backend: audio_backend_name(),
       status: nil
     )}
  end

  # -- UI -------------------------------------------------------------------

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="CONFIG" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text={mode_label(assigns.active, assigns.networks)} text_size={:sm} text_color={:muted} />
        </Row>

        <Column background={:background} padding={:space_lg}>
          <Text text="STATION" text_size={:sm} text_color={:muted} padding={4} />
          <Spacer size={6} />
          <TextField
            value={assigns.station}
            placeholder="STATION NAME / ADDRESS"
            keyboard={:default}
            return_key={:done}
            on_change={{self(), :station_changed}}
          />

          <Spacer size={20} />
          <Divider color={:border} />
          <Spacer size={20} />

          <Row fill_width={true}>
            <Text text="NETWORKS" text_size={:sm} text_color={:muted} />
            <Spacer weight={1} />
            {new_button()}
          </Row>
          <Spacer size={8} />
          {network_list(assigns.networks, assigns.active)}
          <Spacer size={6} />
          <Text text="TAP TO ACTIVATE — ONE NETWORK AT A TIME" text_size={:sm} text_color={:muted} padding={4} />

          <Spacer size={20} />
          <Divider color={:border} />
          <Spacer size={20} />

          <Text text="AUDIO" text_size={:sm} text_color={:muted} padding={4} />
          <Spacer size={6} />
          <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
            <Row fill_width={true}>
              <Text text="BACKEND" text_size={:sm} text_color={:muted} />
              <Spacer weight={1} />
              <Text text={assigns.audio_backend} text_size={:sm} text_color={@amber} />
            </Row>
          </Box>
          <Spacer size={6} />
          <Text text="DIGIRIG NOT DETECTED — LOOPBACK ACTIVE" text_size={:sm} text_color={0xFFB5862A} padding={4} />

          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  # -- Sub-renders ----------------------------------------------------------

  defp new_button do
    ~MOB"""
    <Button text="+ NEW" background={:surface} text_color={:on_surface} text_size={:sm} padding={:space_sm} on_tap={{self(), :new_network}} />
    """
  end

  defp network_list(networks, active) do
    rows = Enum.map(networks, &network_row(&1, active))

    ~MOB"""
    <Column background={@bezel} fill_width={true}>
      {rows}
    </Column>
    """
  end

  defp network_row(%{name: name, type: type}, active) do
    is_active = name == active
    bg = if is_active, do: @active_bg, else: @panel
    name_color = if is_active, do: :on_surface, else: :secondary
    sub = if is_active, do: "#{type_label(type)} — ACTIVE", else: type_label(type)
    sub_color = if is_active, do: @green, else: :muted
    lamp = if is_active, do: @green, else: @bezel

    ~MOB"""
    <Box background={bg} fill_width={true} padding={1}>
      <Row fill_width={true} padding={:space_md} background={bg} on_tap={{self(), {:activate, name}}}>
        <Box background={lamp} width={11} height={11} corner_radius={0} />
        <Spacer size={11} />
        <Column>
          <Text text={name} text_size={:md} text_color={name_color} />
          <Text text={sub} text_size={:sm} text_color={sub_color} />
        </Column>
        <Spacer weight={1} />
        <Text text=">" text_size={:md} text_color={:muted} />
      </Row>
    </Box>
    """
  end

  defp status_line(nil), do: ~MOB(<Spacer size={0} />)

  defp status_line(msg) do
    ~MOB"""
    <Column>
      <Spacer size={16} />
      <Text text={msg} text_size={:sm} text_color={0xFFE8C84A} padding={4} />
    </Column>
    """
  end

  # -- Events ---------------------------------------------------------------

  def handle_info({:change, :station_changed, value}, socket) do
    Mob.State.put(:station_name, value)
    {:noreply, Mob.Socket.assign(socket, station: value)}
  end

  def handle_info({:tap, {:activate, name}}, socket) do
    Mob.State.put(:active_network, name)
    Logger.info("[Config] active network -> #{name}")
    {:noreply, Mob.Socket.assign(socket, active: name, status: "ACTIVATED #{name}")}
  end

  def handle_info({:tap, :new_network}, socket) do
    {name, networks} = append_network(socket.assigns.networks)
    Mob.State.put(:networks, networks)
    {:noreply, Mob.Socket.assign(socket, networks: networks, status: "CREATED #{name} — CONFIGURE IN NETWORK VIEW")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Helpers --------------------------------------------------------------

  defp append_network(networks) do
    n = length(networks) + 1
    name = "NET-#{n}"
    {name, networks ++ [%{name: name, type: :ale}]}
  end

  defp type_label(:ale), do: "ALE NETWORK"
  defp type_label(:data), do: "DATA NETWORK"
  defp type_label(_), do: "UNKNOWN"

  defp mode_label(nil, _networks), do: "STANDBY"

  defp mode_label(active, networks) do
    case Enum.find(networks, &(&1.name == active)) do
      %{type: :ale} -> "ALE"
      %{type: :data} -> "DATA"
      _ -> "STANDBY"
    end
  end

  defp audio_backend_name do
    case Application.get_env(:minutewave, :audio_backend) do
      nil -> "NONE"
      mod -> mod |> Module.split() |> List.last() |> String.upcase()
    end
  end
end
