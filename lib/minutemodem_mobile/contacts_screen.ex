defmodule MinutemodemMobile.ContactsScreen do
  @moduledoc """
  CONTACTS — saved ALE contacts, each addressed in its generation's format.

  Render-only (ShellScreen owns state/events). Each contact is an editable
  card: a name, a generation selector (2G/3G/4G), and the address fields that
  generation uses (2G ASCII, 3G group+member, 4G user-process or PDU). Tapping
  a card selects it as the target for Linking operations (wired separately).

  ## Assigns

    * `:contacts`         — list of `%Contact{}` in display order
    * `:selected_contact` — id of the selected contact, or nil
    * `:status`           — shared status-line text
  """
  use Mob.Screen

  alias MinutemodemMobile.Contacts

  @amber 0xFFE8C84A
  @inset 0xFF060606
  @panel 0xFF0A0A0A
  @bezel 0xFF3A3A3A
  @green 0xFF33C24A
  @active_bg 0xFF0E1A0E
  @disabled 0xFF555555
  @red 0xFFD24A4A

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="CONTACTS" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text={count_label(assigns.contacts)} text_size={:sm} text_color={@amber} />
        </Row>

        <Column background={:background} padding={:space_lg}>
          <Text text="ALE CONTACTS — ADDRESSED PER GENERATION" text_size={:sm} text_color={:muted} padding={2} />
          <Spacer size={12} />
          {contact_rows(assigns.contacts, assigns[:selected_contact])}
          <Spacer size={12} />
          <Box background={@active_bg} border_color={@green} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} on_tap={{self(), {:contact_add}}}>
            <Text text="+ ADD CONTACT" text_size={:md} text_color={@green} />
          </Box>
          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  defp count_label([]), do: "NONE"
  defp count_label(list), do: "#{length(list)}"

  defp contact_rows([], _selected) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Text text="NO CONTACTS — TAP + ADD CONTACT" text_size={:sm} text_color={:muted} />
    </Box>
    """
  end

  defp contact_rows(contacts, selected) do
    cards =
      contacts
      |> Enum.map(&contact_card(&1, &1.id == selected))
      |> Enum.intersperse(~MOB"""
      <Spacer size={10} />
      """)

    ~MOB"""
    <Column fill_width={true}>
      {cards}
    </Column>
    """
  end

  defp contact_card(c, selected?) do
    border = if selected?, do: @green, else: @bezel

    ~MOB"""
    <Box background={@panel} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Column fill_width={true}>
        <Row fill_width={true}>
          <Column on_tap={{self(), {:contact_select, c.id}}}>
            <Text text={select_label(selected?)} text_size={:sm} text_color={select_color(selected?)} />
            <Spacer size={2} />
            <Text text={addr_line(c)} text_size={:md} text_color={@amber} />
          </Column>
          <Spacer weight={1} />
          <Box background={@inset} border_color={@red} border_width={1} corner_radius={0} width={64} padding={10} on_tap={{self(), {:contact_delete, c.id}}}>
            <Text text="DEL" text_size={:sm} text_color={@red} />
          </Box>
        </Row>
        <Spacer size={10} />
        <Text text="NAME" text_size={:sm} text_color={:muted} />
        <Spacer size={2} />
        <TextField value={c.name || ""} placeholder="label" keyboard={:default} return_key={:done} on_change={{self(), {:contact_field, {c.id, "name"}}}} />
        <Spacer size={10} />
        <Text text="GENERATION" text_size={:sm} text_color={:muted} />
        <Spacer size={2} />
        <Row fill_width={true}>
          {gen_button("2G", "2g", c)}
          <Spacer size={6} />
          {gen_button("3G", "3g", c)}
          <Spacer size={6} />
          {gen_button("4G", "4g", c)}
        </Row>
        <Spacer size={10} />
        {gen_fields(c)}
      </Column>
    </Box>
    """
  end

  # Address plus a small trailing generation tag (a footnote, not a chip).
  defp addr_line(c), do: Contacts.display(c) <> "   ·   " <> String.upcase(c.generation)

  defp select_label(true), do: "▸ SELECTED"
  defp select_label(false), do: "TAP TO SELECT"
  defp select_color(true), do: @green
  defp select_color(false), do: @disabled

  # ── generation-specific address fields ──────────────────────────────────

  defp gen_fields(%{generation: "2g"} = c) do
    ~MOB"""
    <Column fill_width={true}>
      <Text text="ADDRESS (2G ALE)" text_size={:sm} text_color={:muted} />
      <Spacer size={2} />
      <TextField value={c.addr_2g || ""} placeholder="e.g. NWFS1" keyboard={:default} return_key={:done} on_change={{self(), {:contact_field, {c.id, "addr_2g"}}}} />
      <Spacer size={4} />
      <Text text="1–15 chars: A–Z 0–9 @ ?" text_size={:sm} text_color={@bezel} />
    </Column>
    """
  end

  defp gen_fields(%{generation: "3g"} = c) do
    packed = Contacts.address_3g(c)
    packed_txt = if packed, do: "PACKED 11-BIT = #{packed}", else: "PACKED 11-BIT = —"

    ~MOB"""
    <Column fill_width={true}>
      <Row fill_width={true}>
        <Column fill_width={true} weight={1}>
          <Text text="DWELL GROUP (0–31)" text_size={:sm} text_color={:muted} />
          <Spacer size={2} />
          <TextField value={int_str(c.grp_3g)} placeholder="0" keyboard={:number_pad} return_key={:done} on_change={{self(), {:contact_field, {c.id, "grp_3g"}}}} />
        </Column>
        <Spacer size={10} />
        <Column fill_width={true} weight={1}>
          <Text text="MEMBER (0–63)" text_size={:sm} text_color={:muted} />
          <Spacer size={2} />
          <TextField value={int_str(c.mbr_3g)} placeholder="0" keyboard={:number_pad} return_key={:done} on_change={{self(), {:contact_field, {c.id, "mbr_3g"}}}} />
        </Column>
      </Row>
      <Spacer size={4} />
      <Text text={packed_txt} text_size={:sm} text_color={@bezel} />
    </Column>
    """
  end

  defp gen_fields(%{generation: "4g"} = c) do
    ~MOB"""
    <Column fill_width={true}>
      <Text text="4G ADDRESS FORM" text_size={:sm} text_color={:muted} />
      <Spacer size={2} />
      <Row fill_width={true}>
        {form_button("USER PROC", "user_process", c)}
        <Spacer size={6} />
        {form_button("PDU", "pdu", c)}
      </Row>
      <Spacer size={10} />
      {form_fields(c)}
      <Spacer size={10} />
      {mp_toggle(c)}
    </Column>
    """
  end

  defp gen_fields(_), do: ~MOB"""
  <Spacer size={0} />
  """

  defp form_fields(%{form_4g: "pdu"} = c) do
    ~MOB"""
    <Column fill_width={true}>
      <Row fill_width={true}>
        <Column fill_width={true} weight={1}>
          <Text text="PDU ADDR (0–65535)" text_size={:sm} text_color={:muted} />
          <Spacer size={2} />
          <TextField value={int_str(c.pdu_4g)} placeholder="0" keyboard={:number_pad} return_key={:done} on_change={{self(), {:contact_field, {c.id, "pdu_4g"}}}} />
        </Column>
        <Spacer size={10} />
        <Column fill_width={true} weight={1}>
          <Text text="NET NUMBER (opt)" text_size={:sm} text_color={:muted} />
          <Spacer size={2} />
          <TextField value={int_str(c.net_4g)} placeholder="—" keyboard={:number_pad} return_key={:done} on_change={{self(), {:contact_field, {c.id, "net_4g"}}}} />
        </Column>
      </Row>
    </Column>
    """
  end

  defp form_fields(c) do
    ~MOB"""
    <Column fill_width={true}>
      <Text text="USER PROCESS ADDRESS" text_size={:sm} text_color={:muted} />
      <Spacer size={2} />
      <TextField value={c.up_4g || ""} placeholder="3–15 chars" keyboard={:default} return_key={:done} on_change={{self(), {:contact_field, {c.id, "up_4g"}}}} />
      <Spacer size={4} />
      <Text text="3–15 printable ASCII characters" text_size={:sm} text_color={@bezel} />
    </Column>
    """
  end

  # Individual-vs-multipoint applies to any 4G contact regardless of how it's
  # addressed: a User Process name can label a multipoint group just as a PDU
  # value can. The multipoint-ness lives in the resolved PDU address either way.
  defp mp_toggle(c) do
    mp = c.multipoint_4g == true

    ~MOB"""
    <Row fill_width={true}>
      <Text text="ADDRESS TYPE" text_size={:sm} text_color={:muted} />
      <Spacer weight={1} />
      <Box background={mp_bg(mp)} border_color={mp_border(mp)} border_width={1} corner_radius={0} width={168} padding={10} on_tap={{self(), {:contact_mp, c.id}}}>
        <Text text={mp_label(mp)} text_size={:sm} text_color={mp_color(mp)} />
      </Box>
    </Row>
    """
  end

  defp mp_label(true), do: "MULTIPOINT"
  defp mp_label(false), do: "INDIVIDUAL (PU)"
  defp mp_bg(true), do: @active_bg
  defp mp_bg(false), do: @inset
  defp mp_border(true), do: @green
  defp mp_border(false), do: @bezel
  defp mp_color(true), do: @green
  defp mp_color(false), do: @amber

  # ── selector buttons ────────────────────────────────────────────────────

  defp gen_button(label, value, c) do
    selected = (c.generation || "4g") == value
    seg(label, selected, {:contact_gen, {c.id, value}})
  end

  defp form_button(label, value, c) do
    selected = (c.form_4g || "user_process") == value
    seg(label, selected, {:contact_form, {c.id, value}})
  end

  defp seg(label, selected, tag) do
    bg = if selected, do: @active_bg, else: @inset
    border = if selected, do: @green, else: @bezel
    color = if selected, do: @green, else: @amber

    ~MOB"""
    <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={{self(), tag}}>
      <Text text={label} text_size={:sm} text_color={color} />
    </Box>
    """
  end

  defp int_str(nil), do: ""
  defp int_str(n) when is_integer(n), do: Integer.to_string(n)
  defp int_str(other), do: to_string(other)

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
end
