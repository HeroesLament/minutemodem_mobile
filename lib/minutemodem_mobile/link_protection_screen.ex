defmodule MinutemodemMobile.LinkProtectionScreen do
  @moduledoc """
  Link Protection — MIL-STD-188-141 Appendix A Linking Protection (LP).

  LP is the anti-spoof / anti-replay layer for ALE link setup: link-setup words
  are protected with AES keyed by a shared key and the disciplined Time-of-Day,
  so a listener can't forge or replay a call. It therefore depends on (a) a
  shared key and (b) a synchronized clock — both surfaced here.

  Render-only (ShellScreen owns state and events). Settings persist into the
  active network's `params` via the generic `{:set_param, {key, value}}` event:

    * `params["lp_enabled"]` — "on" | "off"  (master switch)
    * `params["lp_level"]`   — "0".."4"      (LP0 = none … LP4 = maximum)

  ## Assigns

    * `:net`         — active network (`%{type:, name:, ...}`) or nil
    * `:params`      — active network's params map
    * `:time_status` — `Minutewave.Clock.status/0` map (for TOD sync), or nil
    * `:status`      — shared status line text
  """
  use Mob.Screen

  @amber 0xFFE8C84A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A
  @green 0xFF33C24A
  @active_bg 0xFF0E1A0E
  @red 0xFFD24A4A
  @disabled 0xFF555555

  def mount(_params, _session, socket), do: {:ok, socket}

  # No active network.
  def render(%{net: nil} = assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        {header()}
        <Column background={:background} padding={:space_lg}>
          {empty_panel("NO ACTIVE NETWORK", "Select or create an ALE network in CONFIG, then return here.")}
          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  # Active ALE network — the real controls.
  def render(%{net: %{type: "ale"}} = assigns) do
    params = assigns[:params] || %{}
    enabled = Map.get(params, "lp_enabled", "off")
    level = Map.get(params, "lp_level", "1")

    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        {header(assigns.net.name)}
        <Column background={:background} padding={:space_lg}>
          <Text text="188-141 APPENDIX A LINKING PROTECTION" text_size={:sm} text_color={:muted} padding={2} />
          <Spacer size={4} />
          <Text text="AES-keyed, TOD-varying protection of ALE link-setup words (anti-spoof / anti-replay)." text_size={:sm} text_color={:muted} padding={2} />
          <Spacer size={16} />

          {readiness_panel(enabled, level, assigns[:time_status])}
          <Spacer size={20} />
          <Divider color={:border} />
          <Spacer size={16} />

          <Text text="PROTECTION" text_size={:sm} text_color={:muted} />
          <Spacer size={4} />
          {seg("lp_enabled", [{"ENABLED", "on"}, {"DISABLED", "off"}], enabled)}
          <Spacer size={20} />

          <Text text="LP LEVEL" text_size={:sm} text_color={:muted} />
          <Spacer size={4} />
          {seg("lp_level", [{"LP0", "0"}, {"LP1", "1"}, {"LP2", "2"}, {"LP3", "3"}, {"LP4", "4"}], level)}
          <Spacer size={6} />
          <Text text={level_hint(level)} text_size={:sm} text_color={:muted} padding={4} />
          <Spacer size={20} />
          <Divider color={:border} />
          <Spacer size={16} />

          <Text text="STATUS" text_size={:sm} text_color={:muted} />
          <Spacer size={8} />
          {status_rows(assigns[:time_status])}
          <Spacer size={8} />
          <Text text="Key management (fill/zeroize) is not yet implemented — LP can be configured but won't protect traffic until a key is loaded." text_size={:sm} text_color={0xFFB5862A} padding={4} />

          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  # Active network but not ALE (LP is ALE-only).
  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        {header(assigns.net.name)}
        <Column background={:background} padding={:space_lg}>
          {empty_panel("LINK PROTECTION IS ALE-ONLY", "The active network is a DATA network. Switch to an ALE network to configure Linking Protection.")}
          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  # -- pieces ---------------------------------------------------------------

  defp header(name \\ nil) do
    right = if name, do: String.upcase(to_string(name)), else: "ALE"

    ~MOB"""
    <Row background={:surface} padding={:space_md} fill_width={true}>
      <Text text="LINK PROTECTION" text_size={:lg} text_color={:on_surface} />
      <Spacer weight={1} />
      <Text text={right} text_size={:sm} text_color={@amber} />
    </Row>
    """
  end

  # Top-line readiness: green only when enabled, level>0, clock synced, and a key
  # is present. No key manager yet, so this always reports the missing key.
  defp readiness_panel(enabled, level, time_status) do
    clock_ok = clock_synced?(time_status)
    {label, color, detail} = readiness_display(enabled, level, clock_ok)

    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_lg} fill_width={true}>
      <Row fill_width={true}>
        <Box background={color} width={13} height={13} corner_radius={0} />
        <Spacer size={12} />
        <Column>
          <Text text={label} text_size={:lg} text_color={color} />
          <Spacer size={4} />
          <Text text={detail} text_size={:sm} text_color={:muted} />
        </Column>
      </Row>
    </Box>
    """
  end

  defp status_rows(time_status) do
    {tod_label, tod_color} = tod_display(time_status)

    ~MOB"""
    <Column background={@bezel} fill_width={true}>
      {status_row("TOD SYNC", tod_label, tod_color)}
      {status_row("KEY", "NOT SET", @red)}
    </Column>
    """
  end

  defp status_row(label, value, color) do
    ~MOB"""
    <Box background={:background} fill_width={true} padding={1}>
      <Row fill_width={true} padding={:space_md} background={:background}>
        <Text text={label} text_size={:sm} text_color={:muted} />
        <Spacer weight={1} />
        <Text text={value} text_size={:sm} text_color={color} />
      </Row>
    </Box>
    """
  end

  # Reusable segmented selector — persists via the generic {:set_param, …} event
  # (handled in ShellScreen), same idiom as the Network view.
  defp seg(key, options, current) do
    cells =
      options
      |> Enum.map(fn {text, value} -> seg_cell(text, key, value, current) end)
      |> Enum.intersperse(~MOB"""
      <Spacer size={6} />
      """)

    ~MOB"""
    <Row fill_width={true}>
      {cells}
    </Row>
    """
  end

  defp seg_cell(text, key, value, current) do
    selected = to_string(value) == to_string(current)
    bg = if selected, do: @active_bg, else: @inset
    border = if selected, do: @green, else: @bezel
    color = if selected, do: @green, else: @amber

    ~MOB"""
    <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={{self(), {:set_param, {key, value}}}}>
      <Text text={text} text_size={:sm} text_color={color} />
    </Box>
    """
  end

  defp empty_panel(title, detail) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_lg} fill_width={true}>
      <Text text={title} text_size={:md} text_color={@amber} />
      <Spacer size={8} />
      <Text text={detail} text_size={:sm} text_color={:muted} />
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

  # -- display helpers ------------------------------------------------------

  defp level_hint("0"), do: "LP0 — NO PROTECTION (link-setup words sent in the clear)"
  defp level_hint("1"), do: "LP1 — BASIC AES PROTECTION OF LINK-SETUP WORDS"
  defp level_hint("2"), do: "LP2 — INCREASED WORD PROTECTION"
  defp level_hint("3"), do: "LP3 — HIGH PROTECTION"
  defp level_hint("4"), do: "LP4 — MAXIMUM (full word + address, AES-256 + TOD)"
  defp level_hint(_), do: ""

  defp readiness_display("off", _level, _clock),
    do: {"DISABLED", @amber, "Link setup is unprotected on this network."}

  defp readiness_display("on", "0", _clock),
    do: {"ENABLED · LP0", @amber, "LP0 is no protection — raise the level to protect link setup."}

  defp readiness_display("on", _level, false),
    do: {"NOT READY", @red, "Clock not synced — TOD-varying protection needs a locked/holdover clock."}

  # Enabled, level > 0, clock ok — still blocked on the missing key.
  defp readiness_display("on", _level, true),
    do: {"NOT READY", @red, "No protection key loaded (key management pending)."}

  defp readiness_display(_, _, _), do: {"UNKNOWN", @disabled, "—"}

  defp tod_display(ts) do
    case clock_quality(ts) do
      :locked -> {"LOCKED", @green}
      :holdover -> {"HOLDOVER", @amber}
      :unsynced -> {"UNSYNCED", @red}
      nil -> {"UNAVAILABLE", @disabled}
      other -> {other |> to_string() |> String.upcase(), @amber}
    end
  end

  defp clock_synced?(ts), do: clock_quality(ts) in [:locked, :holdover]

  defp clock_quality(%{quality: q}), do: q
  defp clock_quality(_), do: nil
end
