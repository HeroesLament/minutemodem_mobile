defmodule MinutemodemMobile.LinkingScreen do
  @moduledoc """
  ALE Linking — the operational view with push-button link controls.

  Render-only (like Config/Network): `ShellScreen` owns the state, joins the
  ALE `:pg` broadcast group, drives `Minutewave.ALE.Link`, and calls
  `render/1` with the assigns below.

  This view is *operational*, not configuration: the ALE generation (4G/3G/2G)
  is a property of the network and is set in the NETWORK view; here it is
  read-only context. Only 4G has a working link FSM, so for a non-4G active
  network (or no active ALE network) the controls are disabled with an
  explanatory banner.

  ## Assigns

    * `:ale_net`        — the active ALE %Network{}, or nil
    * `:ale_generation` — "4g" | "3g" | "2g" (from the net's params)
    * `:ale_supported`  — true only for a 4G ALE net (controls live)
    * `:ale_running`    — whether the ALE stack is started for this rig
    * `:ale_state`      — current Link state atom (:idle, :scanning, …)
    * `:ale_info`       — last state-change info map (freq/channel/remote)
    * `:ale_event`      — last {event, payload} for the activity line, or nil
    * `:call_addr`      — current text in the destination-address field
    * `:status`         — shared status line text
  """
  use Mob.Screen

  alias MinutemodemMobile.Contacts

  @amber 0xFFE8C84A
  @panel 0xFF0A0A0A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A
  @green 0xFF33C24A
  @active_bg 0xFF0E1A0E
  @red 0xFFD24A4A
  @disabled 0xFF555555

  def mount(_params, _session, socket), do: {:ok, socket}

  # ── Unsupported: no active ALE net, or active net isn't 4G ───────────────
  def render(%{ale_supported: false} = assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="LINKING" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text="ALE" text_size={:sm} text_color={:muted} />
        </Row>
        <Column background={:background} padding={:space_lg}>
          <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_lg} fill_width={true}>
            {unsupported_body(assigns)}
          </Box>
        </Column>
      </Column>
    </Scroll>
    """
  end

  # ── Supported: 4G ALE net active ─────────────────────────────────────────
  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="LINKING" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text={String.upcase(assigns.ale_net.name)} text_size={:sm} text_color={@amber} />
        </Row>

        <Column background={:background} padding={:space_lg}>
          {state_panel(assigns)}
          <Spacer size={16} />
          {activity_line(assigns.ale_event)}
          <Spacer size={20} />
          <Divider color={:border} />
          <Spacer size={20} />

          {scan_controls(assigns)}
          <Spacer size={18} />
          {channel_select_control(assigns)}
          <Spacer size={18} />
          {call_controls(assigns)}
          <Spacer size={18} />
          {aux_controls(assigns)}

          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  # -- Unsupported body variants --------------------------------------------

  defp unsupported_body(%{ale_net: nil}) do
    ~MOB"""
    <Column>
      <Text text="NO ACTIVE ALE NETWORK" text_size={:md} text_color={@amber} />
      <Spacer size={8} />
      <Text text="Activate an ALE network in CONFIG to use linking." text_size={:sm} text_color={:muted} />
    </Column>
    """
  end

  defp unsupported_body(%{ale_generation: gen}) do
    ~MOB"""
    <Column>
      <Text text={"GENERATION " <> String.upcase(gen || "?") <> " NOT SUPPORTED"} text_size={:md} text_color={@amber} />
      <Spacer size={8} />
      <Text text="Only 188-141D 4G linking is implemented. Set the network's generation to 4G in NETWORK." text_size={:sm} text_color={:muted} />
    </Column>
    """
  end

  # -- Live state panel -----------------------------------------------------

  defp state_panel(assigns) do
    {label, color} = state_display(assigns.ale_state, assigns.ale_running)

    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_lg} fill_width={true}>
      <Row fill_width={true}>
        <Box background={color} width={13} height={13} corner_radius={0} />
        <Spacer size={12} />
        <Column>
          <Text text={label} text_size={:lg} text_color={color} />
          <Spacer size={4} />
          <Text text={detail_line(assigns)} text_size={:sm} text_color={:muted} />
        </Column>
      </Row>
    </Box>
    """
  end

  defp activity_line(nil), do: ~MOB"""
  <Text text="—" text_size={:sm} text_color={@bezel} padding={4} />
  """

  defp activity_line({event, payload}) do
    ~MOB"""
    <Text text={"· " <> format_event(event, payload)} text_size={:sm} text_color={:muted} padding={4} />
    """
  end

  # -- Controls -------------------------------------------------------------

  defp scan_controls(%{ale_state: :scanning} = _assigns) do
    ~MOB"""
    <Column fill_width={true}>
      <Text text="SCAN" text_size={:sm} text_color={:muted} />
      <Spacer size={6} />
      {button("STOP SCAN", {:ale_stop}, @red, @active_bg)}
    </Column>
    """
  end

  defp scan_controls(_assigns) do
    ~MOB"""
    <Column fill_width={true}>
      <Text text="SCAN" text_size={:sm} text_color={:muted} />
      <Spacer size={6} />
      {button("START SCAN", {:ale_scan}, @green, @panel)}
    </Column>
    """
  end

  # Operator control: how the calling frequency is chosen. MANUAL = operator's
  # channel; AUTO = ACS/LQA picks the best channel for the destination. Persists
  # to the active net's params via ShellScreen's {:set_param, …} handler.
  # NOTE: reuses the segmented primitive; TODO dedup with NetworkScreen into a
  # shared UI module.
  defp channel_select_control(assigns) do
    current = Map.get(assigns[:params] || %{}, "lqa_channel_select", "manual")

    ~MOB"""
    <Column fill_width={true}>
      {segmented("CHANNEL SELECT", "lqa_channel_select", [{"MANUAL", "manual"}, {"AUTO", "auto"}], current)}
      <Spacer size={4} />
      <Text text="AUTO PICKS BEST CHANNEL BY LQA" text_size={:sm} text_color={:muted} padding={4} />
    </Column>
    """
  end

  defp segmented(label, key, options, current) do
    cells =
      options
      |> Enum.map(fn {text, value} -> seg_button(text, key, value, current) end)
      |> Enum.intersperse(seg_gap())

    ~MOB"""
    <Column fill_width={true}>
      <Text text={label} text_size={:sm} text_color={:muted} />
      <Spacer size={4} />
      <Row fill_width={true}>
        {cells}
      </Row>
    </Column>
    """
  end

  defp seg_button(text, key, value, current) do
    selected = value == current
    bg = if selected, do: @active_bg, else: @inset
    border = if selected, do: @green, else: @bezel
    text_color = if selected, do: @green, else: @amber

    ~MOB"""
    <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={{self(), {:set_param, {key, value}}}}>
      <Text text={text} text_size={:md} text_color={text_color} />
    </Box>
    """
  end

  defp seg_gap do
    ~MOB"""
    <Spacer size={8} />
    """
  end

  defp call_controls(assigns) do
    selected = selected_contact(assigns)

    ~MOB"""
    <Column fill_width={true}>
      <Text text="CALL" text_size={:sm} text_color={:muted} />
      <Spacer size={6} />
      {call_target(assigns, selected)}
      <Spacer size={8} />
      {call_button(assigns, selected)}
    </Column>
    """
  end

  # The selected target is held by contact id (not a copied string); resolve it
  # to the live %Contact{} so CALL reads its raw address values directly.
  defp selected_contact(assigns) do
    case assigns[:selected_contact] do
      nil -> nil
      id -> Enum.find(assigns[:contacts] || [], &(&1.id == id))
    end
  end

  # No target chosen: search field + live contact autocomplete (or type a raw
  # numeric address for an ad-hoc call).
  defp call_target(assigns, nil) do
    ~MOB"""
    <Column fill_width={true}>
      <TextField
        value={assigns.call_addr}
        placeholder="SEARCH CONTACT OR TYPE ADDRESS (e.g. 1002)"
        keyboard={:default}
        return_key={:done}
        on_change={{self(), :call_addr_changed}}
      />
      {contact_suggestions(assigns)}
    </Column>
    """
  end

  # Target chosen: show the contact's box in place, with its concrete resolved
  # address (incl. hex for numeric/PDU targets). CLEAR returns to search.
  defp call_target(_assigns, c) do
    ~MOB"""
    <Box background={@inset} border_color={@green} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Column fill_width={true}>
        <Row fill_width={true}>
          <Text text={to_string(c.name)} text_size={:md} text_color={@green} />
          <Spacer weight={1} />
          <Box background={@panel} border_color={@bezel} border_width={1} corner_radius={0} width={110} padding={12} on_tap={{self(), {:contact_clear}}}>
            <Text text="CLEAR" text_size={:sm} text_color={@amber} />
          </Box>
        </Row>
        <Spacer size={10} />
        <Text text={target_line(c)} text_size={:sm} text_color={:muted} />
      </Column>
    </Box>
    """
  end

  # Concrete target readout: generation + the human display, plus the raw wire
  # value in hex for numeric/PDU targets, or a "not callable" note for a User
  # Process name that has no PDU address to transmit.
  defp target_line(c) do
    base = String.upcase(to_string(c.generation)) <> "   ·   " <> MinutemodemMobile.Contacts.display(c)

    case MinutemodemMobile.Contacts.dest(c) do
      {:addr, n} -> base <> "   ·   0x" <> String.upcase(Integer.to_string(n, 16))
      {:user_process, _} -> base <> "   ·   (no PDU addr — not callable)"
      {:error, :incomplete} -> base <> "   ·   INCOMPLETE"
      _ -> base
    end
  end

  # Live contact autocomplete: as the operator types a destination, match it
  # against every saved contact across all address formats and offer the hits
  # as a tappable list right under the field (Mob has no floating-dropdown
  # widget, and inline avoids keyboard/z-order problems). Tapping one fills the
  # field with its resolved address and selects it. Suppressed once the field
  # already exactly equals a match (i.e. the operator has committed a pick).
  defp contact_suggestions(assigns) do
    query = assigns[:call_addr] || ""
    matches = assigns[:contacts] |> List.wrap() |> Contacts.search(query) |> Enum.take(3)

    if show_suggestions?(matches, query) do
      rows =
        matches
        |> Enum.map(&suggestion_row(&1, &1.id == assigns[:selected_contact]))

      ~MOB"""
      <Column fill_width={true}>
        <Spacer size={4} />
        <Box background={@inset} border_color={@green} border_width={1} corner_radius={0} fill_width={true}>
          <Column fill_width={true}>
            {rows}
          </Column>
        </Box>
      </Column>
      """
    else
      ~MOB"""
      <Spacer size={0} />
      """
    end
  end

  # Hide the list once the query exactly matches a hit's name or resolved value
  # (the operator has already selected/typed a complete address).
  defp show_suggestions?([], _query), do: false

  defp show_suggestions?(matches, query) do
    q = String.trim(query)

    not Enum.any?(matches, fn c ->
      q == to_string(c.name) or q == Contacts.call_value(c)
    end)
  end

  defp suggestion_row(c, selected?) do
    dot = if selected?, do: @green, else: @bezel

    ~MOB"""
    <Box background={@panel} fill_width={true} padding={1}>
      <Row fill_width={true} padding={:space_md} background={@panel} on_tap={{self(), {:contact_pick, c.id}}}>
        <Box background={dot} width={9} height={9} corner_radius={0} />
        <Spacer size={10} />
        <Column fill_width={true} weight={1}>
          <Text text={suggestion_primary(c)} text_size={:md} text_color={@amber} />
          <Text text={suggestion_secondary(c)} text_size={:sm} text_color={:muted} />
        </Column>
      </Row>
    </Box>
    """
  end

  # Lead the row with the contact's name (the useful identifier). If a contact
  # has no name yet, fall back to its address so the row is never just "4G".
  defp suggestion_primary(c) do
    case String.trim(to_string(c.name)) do
      "" -> Contacts.display(c)
      name -> name
    end
  end

  # Secondary line: the resolved address plus a small generation tag. When the
  # name was blank (address is already the primary), show just the generation.
  defp suggestion_secondary(c) do
    gen = String.upcase(to_string(c.generation))

    case String.trim(to_string(c.name)) do
      "" ->
        gen <> " ADDRESS"

      _ ->
        case Contacts.display(c) do
          disp when disp in ["", "—"] -> gen
          disp -> disp <> "   ·   " <> gen
        end
    end
  end

  # Disable CALL while already linked/calling.
  defp call_button(%{ale_state: state}, _selected)
       when state in [:calling, :linked, :lbt, :lbr, :responding],
       do: disabled_call()

  # No contact target: enabled only if a manual address was typed.
  defp call_button(%{call_addr: addr}, nil) when addr in [nil, ""], do: disabled_call()
  defp call_button(_assigns, nil), do: button("CALL", {:ale_call}, @green, @panel)

  # Contact target: callable only if it resolves to a numeric wire address (a
  # User Process name with no PDU address can't be transmitted).
  defp call_button(_assigns, c) do
    case MinutemodemMobile.Contacts.dest(c) do
      {:addr, _} -> button("CALL", {:ale_call}, @green, @panel)
      _ -> disabled_call()
    end
  end

  defp disabled_call do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Text text="CALL" text_size={:md} text_color={@disabled} />
    </Box>
    """
  end

  defp aux_controls(assigns) do
    ~MOB"""
    <Row fill_width={true}>
      {button("SOUND", {:ale_sound}, @amber, @panel)}
      <Spacer size={10} />
      {terminate_button(assigns)}
    </Row>
    """
  end

  defp terminate_button(%{ale_state: :linked}) do
    button("TERMINATE", {:ale_terminate}, @red, @active_bg)
  end

  defp terminate_button(_assigns) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md}>
      <Text text="TERMINATE" text_size={:md} text_color={@disabled} />
    </Box>
    """
  end

  defp button(label, tag, text_color, bg) do
    ~MOB"""
    <Box background={bg} border_color={text_color} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} on_tap={{self(), tag}}>
      <Text text={label} text_size={:md} text_color={text_color} />
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
      <Text text={msg} text_size={:sm} text_color={@amber} padding={4} />
    </Column>
    """
  end

  # -- Display helpers ------------------------------------------------------

  # Maps Link state → {label, color}. When the stack isn't running yet, show a
  # neutral "READY" so the operator knows tapping SCAN will spin it up.
  defp state_display(_state, false), do: {"READY — START SCAN", @amber}
  defp state_display(:idle, _), do: {"IDLE", @amber}
  defp state_display(:scanning, _), do: {"SCANNING", @green}
  defp state_display(:sounding, _), do: {"SOUNDING", @green}
  defp state_display(:lbt, _), do: {"LISTEN BEFORE TX", @amber}
  defp state_display(:calling, _), do: {"CALLING", @green}
  defp state_display(:lbr, _), do: {"LISTEN BEFORE RESPOND", @amber}
  defp state_display(:responding, _), do: {"RESPONDING", @green}
  defp state_display(:linked, _), do: {"LINKED", @green}
  defp state_display(:terminating, _), do: {"TERMINATING", @red}
  defp state_display(other, _), do: {other |> to_string() |> String.upcase(), @amber}

  defp detail_line(%{ale_info: info}) when is_map(info) do
    parts =
      []
      |> maybe_part(info[:freq_hz], fn f -> format_freq(f) end)
      |> maybe_part(info[:channel], fn ch -> channel_label(ch) end)
      |> maybe_part(info[:remote_addr], fn a -> "→ 0x" <> Integer.to_string(a, 16) end)

    case parts do
      [] -> "—"
      ps -> Enum.join(ps, "   ")
    end
  end

  defp detail_line(_), do: "—"

  defp maybe_part(parts, nil, _f), do: parts
  defp maybe_part(parts, val, f), do: parts ++ [f.(val)]

  defp channel_label(%{name: n}) when is_binary(n) and n != "", do: n
  defp channel_label(%{"name" => n}) when is_binary(n) and n != "", do: n
  defp channel_label(_), do: nil

  defp format_event(event, payload) when is_map(payload) and map_size(payload) == 0,
    do: event |> to_string() |> String.upcase()

  defp format_event(event, payload),
    do: (event |> to_string() |> String.upcase()) <> " " <> inspect(payload)

  defp format_freq(nil), do: nil

  defp format_freq(hz) when is_integer(hz) and hz >= 1_000_000 do
    mhz = Float.round(hz / 1_000_000, 3)
    "#{mhz} MHz"
  end

  defp format_freq(hz), do: "#{hz} Hz"
end
