defmodule MinutemodemMobile.NetworkTimeScreen do
  @moduledoc """
  Network Time — disciplined virtual clock status + peer-TOD control.

  Render-only (ShellScreen owns state). Shows the `Minutewave.Clock` status:
  quality (LOCKED / HOLDOVER / UNSYNCED), uncertainty, the disciplining source
  (SYSTEM fallback / GNSS / PEER-TOD), stratum, current UTC, and GNSS fix info.

  The NETWORK / OUTSIDE control toggles `Clock.set_tod_admissible/1` — whether
  this station may slave its clock to a peer's Time-of-Day distribution
  (NETWORK) or trust only its own GNSS/system source (OUTSIDE).

  ## Assigns

    * `:time_status` — `Minutewave.Clock.status/0` map, or nil if unavailable
    * `:gnss_status` — `MinutemodemMobile.Gnss.status/0` map, or nil
    * `:status`      — shared status line text
  """
  use Mob.Screen

  @amber 0xFFE8C84A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A
  @green 0xFF33C24A
  @active_bg 0xFF0E1A0E
  @red 0xFFD24A4A

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(%{time_status: nil} = assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        {header()}
        <Column background={:background} padding={:space_lg}>
          <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
            <Text text="CLOCK UNAVAILABLE" text_size={:sm} text_color={:muted} />
          </Box>
          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  def render(assigns) do
    ts = assigns.time_status

    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        {header()}
        <Column background={:background} padding={:space_lg}>
          {quality_panel(ts)}
          <Spacer size={16} />
          {info_rows(ts, assigns.gnss_status)}
          <Spacer size={20} />
          <Divider color={:border} />
          <Spacer size={16} />
          <Text text="TIME SOURCE" text_size={:sm} text_color={:muted} />
          <Spacer size={6} />
          {tod_toggle(ts.tod_admissible)}
          <Spacer size={4} />
          <Text text="NETWORK = SLAVE TO A PEER'S TOD · OUTSIDE = OWN GNSS/SYSTEM ONLY" text_size={:sm} text_color={:muted} padding={4} />
          <Spacer size={16} />
          {refresh_row()}
          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  # -- pieces ---------------------------------------------------------------

  defp header do
    ~MOB"""
    <Row background={:surface} padding={:space_md} fill_width={true}>
      <Text text="NETWORK TIME" text_size={:lg} text_color={:on_surface} />
      <Spacer weight={1} />
      <Text text="CLOCK" text_size={:sm} text_color={:muted} />
    </Row>
    """
  end

  defp quality_panel(ts) do
    {label, color} = quality_display(ts.quality)

    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_lg} fill_width={true}>
      <Row fill_width={true}>
        <Box background={color} width={13} height={13} corner_radius={0} />
        <Spacer size={12} />
        <Column>
          <Text text={label} text_size={:lg} text_color={color} />
          <Spacer size={4} />
          <Text text={"±#{unc_text(ts.uncertainty_ms)}"} text_size={:sm} text_color={:muted} />
        </Column>
        <Spacer weight={1} />
        <Text text={utc_text(ts.protocol_time_ms)} text_size={:md} text_color={@amber} />
      </Row>
    </Box>
    """
  end

  defp info_rows(ts, gnss) do
    ~MOB"""
    <Column background={@bezel} fill_width={true}>
      {info_row("SOURCE", source_text(ts))}
      {info_row("STRATUM", stratum_text(ts.stratum))}
      {info_row("GNSS FIXES", gnss_text(gnss))}
      {info_row("SATELLITES", sats_text(gnss))}
      {signal_row(gnss)}
      {info_row("CONSTELLATIONS", constellations_text(gnss))}
      {info_row("TTFF", ttff_text(gnss))}
    </Column>
    """
  end

  # C/N0 gets its own colored row so the operator can watch signal come up.
  defp signal_row(gnss) do
    {text, color} = signal_display(gnss)

    ~MOB"""
    <Box background={:background} fill_width={true} padding={1}>
      <Row fill_width={true} padding={:space_md} background={:background}>
        <Text text="SIGNAL (C/N0)" text_size={:sm} text_color={:muted} />
        <Spacer weight={1} />
        <Text text={text} text_size={:sm} text_color={color} />
      </Row>
    </Box>
    """
  end

  defp info_row(label, value) do
    ~MOB"""
    <Box background={:background} fill_width={true} padding={1}>
      <Row fill_width={true} padding={:space_md} background={:background}>
        <Text text={label} text_size={:sm} text_color={:muted} />
        <Spacer weight={1} />
        <Text text={value} text_size={:sm} text_color={@amber} />
      </Row>
    </Box>
    """
  end

  defp tod_toggle(admissible) do
    ~MOB"""
    <Row fill_width={true}>
      {tod_cell("NETWORK", true, admissible)}
      <Spacer size={8} />
      {tod_cell("OUTSIDE", false, admissible)}
    </Row>
    """
  end

  defp tod_cell(label, value, current) do
    selected = value == current
    bg = if selected, do: @active_bg, else: @inset
    border = if selected, do: @green, else: @bezel
    text_color = if selected, do: @green, else: @amber

    ~MOB"""
    <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={{self(), {:set_tod_admissible, value}}}>
      <Text text={label} text_size={:md} text_color={text_color} />
    </Box>
    """
  end

  defp refresh_row do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} on_tap={{self(), :time_refresh}}>
      <Text text="↻ REFRESH" text_size={:sm} text_color={@amber} />
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

  defp quality_display(:locked), do: {"LOCKED", @green}
  defp quality_display(:holdover), do: {"HOLDOVER", @amber}
  defp quality_display(:unsynced), do: {"UNSYNCED", @red}
  defp quality_display(other), do: {other |> to_string() |> String.upcase(), @amber}

  defp unc_text(:infinity), do: "∞"
  defp unc_text(ms) when is_number(ms), do: "#{ms}ms"
  defp unc_text(_), do: "—"

  # Source label: OS fallback if never disciplined, else the disciplining source.
  defp source_text(%{disciplined: false}), do: "SYSTEM (OS FALLBACK)"
  defp source_text(%{source_name: "gnss"}), do: "GNSS"
  defp source_text(%{source_name: "tod"}), do: "PEER TOD"
  defp source_text(%{source_name: name}) when is_binary(name), do: String.upcase(name)
  defp source_text(_), do: "—"

  defp stratum_text(n) when is_integer(n), do: Integer.to_string(n)
  defp stratum_text(_), do: "—"

  defp gnss_text(%{fix_count: n} = g) when is_integer(n) do
    base = "#{n} fix#{if n == 1, do: "", else: "es"}"
    acq = if Map.get(g, :acquiring), do: " · ACQUIRING", else: " · STANDBY"

    case Map.get(g, :permission) do
      :denied -> base <> " · PERM DENIED"
      :pending -> base <> " · AWAITING PERM"
      _ -> base <> acq
    end
  end

  defp gnss_text(_), do: "—"

  defp sats_text(%{sats_used: u, sats_visible: v}) when is_integer(u) and is_integer(v),
    do: "#{u} / #{v} used"

  defp sats_text(_), do: "—"

  # Signal strength: green ≥ 35, amber ≥ 25, red > 0 dB-Hz.
  defp signal_display(%{max_cn0: c}) when is_integer(c) and c > 0 do
    color =
      cond do
        c >= 35 -> @green
        c >= 25 -> @amber
        true -> @red
      end

    {"#{c} dB-Hz", color}
  end

  defp signal_display(_), do: {"—", @bezel}

  defp constellations_text(%{constellations: s}) when is_binary(s) and s != "", do: s
  defp constellations_text(_), do: "—"

  defp ttff_text(%{ttff_ms: ms}) when is_integer(ms) and ms > 0 do
    "#{Float.round(ms / 1000, 1)} s"
  end

  defp ttff_text(_), do: "—"

  defp utc_text(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} ->
        Calendar.strftime(dt, "%H:%M:%S UTC")

      _ ->
        "—"
    end
  end

  defp utc_text(_), do: "—"
end
