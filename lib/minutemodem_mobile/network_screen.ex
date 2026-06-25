defmodule MinutemodemMobile.NetworkScreen do
  @moduledoc """
  Per-network configuration — edits parameters of the active network
  (selected in Config). Content is conditional on network type: ALE shows
  self address / channel list / sounding interval; DATA shows frequency /
  data rate / interleaver. Parameters persist into the network's params map
  via Networks.update_params/2. No active network -> empty state.
  """
  use Mob.Screen
  alias MinutemodemMobile.Networks

  @amber 0xFFE8C84A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A

  def mount(_params, _session, socket) do
    {:ok, assign_active(socket, status: nil)}
  end

  defp assign_active(socket, extra) do
    net = Networks.active()

    socket
    |> Mob.Socket.assign(net: net, params: (net && net.params) || %{})
    |> Mob.Socket.assign(extra)
  end

  def render(%{net: nil} = _assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="NETWORK" text_size={:lg} text_color={:on_surface} />
        </Row>
        <Spacer size={24} />
        <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_lg} fill_width={true}>
          <Text text="NO ACTIVE NETWORK" text_size={:md} text_color={@amber} />
          <Spacer size={8} />
          <Text text="Select or create a network in CONFIG, then return here." text_size={:sm} text_color={:muted} />
        </Box>
      </Column>
    </Scroll>
    """
  end

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="NETWORK" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text={String.upcase(assigns.net.name)} text_size={:sm} text_color={@amber} />
        </Row>
        <Column background={:background} padding={:space_lg}>
          <Text text={type_banner(assigns.net.type)} text_size={:sm} text_color={:muted} padding={4} />
          <Spacer size={12} />
          {param_fields(assigns.net.type, assigns.params)}
          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  defp param_fields("ale", params) do
    ~MOB"""
    <Column fill_width={true}>
      {field("SELF ADDRESS", "self_addr", Map.get(params, "self_addr", ""), "e.g. 1001")}
      <Spacer size={14} />
      {field("CHANNEL LIST (HZ, COMMA-SEP)", "channels", Map.get(params, "channels", ""), "7102000,10145000")}
      <Spacer size={14} />
      {field("SOUNDING INTERVAL (S)", "sounding_interval", Map.get(params, "sounding_interval", ""), "300")}
    </Column>
    """
  end

  defp param_fields("data", params) do
    ~MOB"""
    <Column fill_width={true}>
      {field("FREQUENCY (HZ)", "freq_hz", Map.get(params, "freq_hz", ""), "7102000")}
      <Spacer size={14} />
      {field("DATA RATE (BPS)", "data_rate", Map.get(params, "data_rate", ""), "2400")}
      <Spacer size={14} />
      {field("INTERLEAVER", "interleaver", Map.get(params, "interleaver", ""), "short / long")}
    </Column>
    """
  end

  defp param_fields(_unknown, _params) do
    ~MOB"""
    <Text text="UNKNOWN NETWORK TYPE" text_size={:sm} text_color={:muted} />
    """
  end

  defp field(label, key, value, placeholder) do
    tag = {self(), {:param_change, key}}

    ~MOB"""
    <Column fill_width={true}>
      <Text text={label} text_size={:sm} text_color={:muted} />
      <Spacer size={4} />
      <TextField value={value} placeholder={placeholder} keyboard={:default} return_key={:done} on_change={tag} />
    </Column>
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

  def handle_info({:change, {:param_change, key}, value}, socket) do
    case socket.assigns.net do
      nil ->
        {:noreply, socket}

      net ->
        case Networks.update_params(net, %{key => value}) do
          {:ok, updated} ->
            {:noreply,
             Mob.Socket.assign(socket, net: updated, params: updated.params, status: "SAVED " <> String.upcase(key))}

          {:error, _cs} ->
            {:noreply, Mob.Socket.assign(socket, status: "SAVE FAILED")}
        end
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp type_banner("ale"), do: "ALE NETWORK PARAMETERS"
  defp type_banner("data"), do: "DATA NETWORK PARAMETERS"
  defp type_banner(_), do: "PARAMETERS"
end
