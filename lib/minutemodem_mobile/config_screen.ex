defmodule MinutemodemMobile.ConfigScreen do
  @moduledoc """
  Station configuration.

    * STATION — name/address, persisted in `Mob.State` (:station_name); it's
      a singleton setting, not a relational entity.
    * NETWORKS — backed by Ecto via `MinutemodemMobile.Networks`. Each is a
      %Network{name, type, active, params}; exactly one is active (the modem
      is mode-exclusive). Tap a row to activate; "+ NEW" creates one. The
      per-row chevron will open the Network view (per-network params) once
      that screen exists.
    * AUDIO — read-only readout of the active Minutewave.Audio.Backend. No
      device picker yet (the behaviour has no enumeration callback); a real
      one lands with a DigiRig backend + list_devices seam.

  Tactical styling via color tokens + bordered Boxes (corner_radius 0, amber
  values, green active accent, uppercase labels). The mono terminal look is
  an iOS-only enhancement (Android ignores the font prop) and isn't depended
  on here.
  """
  use Mob.Screen
  require Logger

  alias MinutemodemMobile.Networks

  @amber 0xFFE8C84A
  @panel 0xFF0A0A0A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A
  @active_bg 0xFF0E1A0E
  @green 0xFF33C24A

  # -- Lifecycle ------------------------------------------------------------

  # Render-only module: ShellScreen owns mount/state/events and calls
  # render/1 with the needed assigns. mount/3 is kept minimal to satisfy the
  # Mob.Screen behaviour (this screen is never started standalone).
  def mount(_params, _session, socket), do: {:ok, socket}

  # -- UI -------------------------------------------------------------------

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="CONFIG" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text={mode_label(assigns.active_type)} text_size={:sm} text_color={:muted} />
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
          {network_list(assigns.networks, assigns.active_name)}
          <Spacer size={6} />
          <Text text="TAP TO ACTIVATE — ONE NETWORK AT A TIME" text_size={:sm} text_color={:muted} padding={4} />
          <Spacer size={10} />
          <Row fill_width={true}>
            {io_button("IMPORT JSON", {:net_import}, @green)}
            <Spacer size={8} />
            {io_button("EXPORT ACTIVE", {:net_export}, @amber)}
          </Row>

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
          {digirig_line(assigns.digirig_status)}

          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  defp new_button do
    ~MOB"""
    <Button text="+ NEW" background={:surface} text_color={:on_surface} text_size={:sm} padding={:space_sm} on_tap={{self(), :new_network}} />
    """
  end

  # Import/export a network as JSON. Import opens the OS document picker;
  # export shares the active network's JSON via the OS share sheet.
  defp io_button(label, tag, color) do
    ~MOB"""
    <Box background={@inset} border_color={color} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={{self(), tag}}>
      <Text text={label} text_size={:sm} text_color={color} />
    </Box>
    """
  end

  defp network_list([], _active) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Text text="NO NETWORKS — TAP + NEW" text_size={:sm} text_color={:muted} />
    </Box>
    """
  end

  defp network_list(networks, active_name) do
    rows = Enum.map(networks, &network_row(&1, active_name))

    ~MOB"""
    <Column background={@bezel} fill_width={true}>
      {rows}
    </Column>
    """
  end

  defp network_row(%{name: name, type: type}, active_name) do
    is_active = name == active_name
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

  defp status_line(nil), do: ~MOB"""
  <Spacer size={0} />
  """

  defp status_line(msg) do
    ~MOB"""
    <Column>
      <Spacer size={16} />
      <Text text={msg} text_size={:sm} text_color={0xFFE8C84A} padding={4} />
    </Column>
    """
  end

  # -- Helpers --------------------------------------------------------------

  # DigiRig session status line, driven by the modem Manager's status atom.
  # The modem is idle until a session is deliberately started, so :idle is
  # "no session" rather than "no hardware".
  defp digirig_line(:ready) do
    ~MOB"""
    <Text text="DIGIRIG SESSION ACTIVE" text_size={:sm} text_color={@green} padding={4} />
    """
  end

  defp digirig_line(:tx) do
    ~MOB"""
    <Text text="DIGIRIG — TRANSMITTING" text_size={:sm} text_color={@green} padding={4} />
    """
  end

  defp digirig_line(:opening) do
    ~MOB"""
    <Text text="DIGIRIG — CONNECTING…" text_size={:sm} text_color={@amber} padding={4} />
    """
  end

  defp digirig_line(:unavailable) do
    ~MOB"""
    <Text text="MODEM UNAVAILABLE" text_size={:sm} text_color={0xFFB5862A} padding={4} />
    """
  end

  # :idle (or anything else): resident but no hardware session started.
  defp digirig_line(_) do
    ~MOB"""
    <Text text="NO SESSION — START MODEM TO CONNECT DIGIRIG" text_size={:sm} text_color={0xFFB5862A} padding={4} />
    """
  end

  defp type_label("ale"), do: "ALE NETWORK"
  defp type_label("data"), do: "DATA NETWORK"
  defp type_label(_), do: "UNKNOWN"

  defp mode_label("ale"), do: "ALE"
  defp mode_label("data"), do: "DATA"
  defp mode_label(_), do: "STANDBY"

end
