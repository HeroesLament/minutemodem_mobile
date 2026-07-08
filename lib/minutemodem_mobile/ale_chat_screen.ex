defmodule MinutemodemMobile.AleChatScreen do
  @moduledoc """
  ALE Text Chat (MIL-STD-188-141D 4G, G.5.6).

  Chat lives *on an active link*: you Call a station from the LINKING tab, and
  once the link is up this tab lets you exchange text with the far end — an
  individual station or a multipoint net. Messages are unacknowledged, so a
  "sent" bubble means transmitted, never confirmed-delivered.

  Render-only: ShellScreen owns state (`chat_peer`, `chat_thread`,
  `chat_draft`, `ale_state`) and the `{:chat_send}` / `:chat_changed` events.
  """
  use Mob.Screen

  @amber 0xFFE8C84A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A
  @green 0xFF33C24A
  @sent_bg 0xFF171206
  @recv_bg 0xFF0E1A0E

  def mount(_params, _session, socket), do: {:ok, socket}

  # -- Linked: full chat surface -------------------------------------------

  def render(%{ale_state: :linked} = assigns) do
    peer = assigns[:chat_peer]
    assigns = Map.put(assigns, :peer_label, "ON LINK · 0x" <> addr_hex(peer))

    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="ALE CHAT" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text={assigns.peer_label} text_size={:sm} text_color={@green} />
        </Row>

        <Column background={:background} padding={:space_lg}>
          {thread_view(assigns.chat_thread)}

          <Spacer size={12} />
          <TextField
            value={assigns.chat_draft}
            placeholder="TYPE A MESSAGE…"
            keyboard={:default}
            return_key={:done}
            on_change={{self(), :chat_changed}}
          />
          <Spacer size={8} />
          <Box background={@inset} border_color={@amber} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} on_tap={{self(), {:chat_send}}}>
            <Text text="SEND" text_size={:md} text_color={@amber} />
          </Box>
          <Spacer size={6} />
          <Text text="UNACKNOWLEDGED — 'SENT' IS NOT 'DELIVERED'" text_size={:sm} text_color={:muted} padding={4} />
        </Column>
      </Column>
    </Scroll>
    """
  end

  # -- Not linked: gated empty state ---------------------------------------

  def render(assigns) do
    _ = assigns

    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="ALE CHAT" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text="NO LINK" text_size={:sm} text_color={:muted} />
        </Row>

        <Column background={:background} padding={:space_lg}>
          <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
            <Text
              text="NO ACTIVE LINK. CALL A STATION FROM THE LINKING TAB, THEN RETURN HERE TO CHAT ON THE LINK."
              text_size={:sm}
              text_color={:muted}
            />
          </Box>
        </Column>
      </Column>
    </Scroll>
    """
  end

  # -- Thread -------------------------------------------------------------

  defp thread_view([]) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Text text="NO MESSAGES YET — SAY SOMETHING." text_size={:sm} text_color={:muted} />
    </Box>
    """
  end

  defp thread_view(messages) do
    rows = Enum.map(messages, &bubble/1)

    ~MOB"""
    <Column fill_width={true}>
      {rows}
    </Column>
    """
  end

  # Sent: amber, right-aligned.
  defp bubble(%{direction: "sent"} = msg) do
    assigns = %{text: msg.text}

    ~MOB"""
    <Column fill_width={true}>
      <Row fill_width={true}>
        <Spacer weight={1} />
        <Box background={@sent_bg} border_color={@amber} border_width={1} corner_radius={0} padding={:space_md} weight={3}>
          <Text text={assigns.text} text_size={:md} text_color={@amber} />
        </Box>
      </Row>
      <Spacer size={6} />
    </Column>
    """
  end

  # Received: green, left-aligned, with the originating station's address (so a
  # net conversation shows who said what).
  defp bubble(%{direction: "received"} = msg) do
    assigns = %{text: msg.text, from: "0x" <> addr_hex(msg.sender_addr)}

    ~MOB"""
    <Column fill_width={true}>
      <Row fill_width={true}>
        <Box background={@recv_bg} border_color={@green} border_width={1} corner_radius={0} padding={:space_md} weight={3}>
          <Column>
            <Text text={assigns.from} text_size={:sm} text_color={:muted} />
            <Spacer size={2} />
            <Text text={assigns.text} text_size={:md} text_color={@green} />
          </Column>
        </Box>
        <Spacer weight={1} />
      </Row>
      <Spacer size={6} />
    </Column>
    """
  end

  defp addr_hex(nil), do: "????"

  defp addr_hex(a) when is_integer(a),
    do: a |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0")
end
