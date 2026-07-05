defmodule MinutemodemMobile.LinkQualityScreen do
  @moduledoc """
  Link Quality — LQA history for the active network.

  Render-only (like Config/Network/Linking): `ShellScreen` owns the state,
  loads the summaries from `MinutemodemMobile.LinkQuality`, and calls `render/1`
  with the assigns below.

  Two sections:

    * CHANNELS — each configured frequency ranked best-first by average LQA
      score in the window, with observation count and last-heard.
    * STATIONS — each station heard, most-recently-heard first, with its
      average and latest score, last SNR, and RX/TX direction.

  ## Assigns

    * `:ale_net`      — the active ALE %Network{}, or nil (for the header)
    * `:lqa_channels` — [%{freq_hz, score, last_heard, count}], best first
    * `:lqa_stations` — [%{addr, name, score, last_score, snr_db, directions,
      last_heard, count}], newest first
    * `:status`       — shared status line text
  """
  use Mob.Screen

  @amber 0xFFE8C84A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A
  @panel 0xFF0A0A0A
  @green 0xFF33C24A
  @muted_amber 0xFFB5862A
  @red 0xFFD24A4A

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="LINK QUALITY" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text={header_label(assigns)} text_size={:sm} text_color={@amber} />
        </Row>
        <Column background={:background} padding={:space_lg}>
          {refresh_row()}
          <Spacer size={16} />
          <Text text="CHANNELS" text_size={:sm} text_color={:muted} />
          <Spacer size={6} />
          {channel_section(assigns.lqa_channels)}
          <Spacer size={20} />
          <Divider color={:border} />
          <Spacer size={20} />
          <Text text="STATIONS" text_size={:sm} text_color={:muted} />
          <Spacer size={6} />
          {station_section(assigns.lqa_stations)}
          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  # -- Channels -------------------------------------------------------------

  defp channel_section([]) do
    empty_box("NO CHANNEL DATA — SET A CHANNEL LIST IN NETWORK, THEN SCAN/SOUND")
  end

  defp channel_section(channels) do
    rows = Enum.map(channels, &channel_row/1)

    ~MOB"""
    <Column background={@bezel} fill_width={true}>
      {rows}
    </Column>
    """
  end

  defp channel_row(%{freq_hz: freq, score: score, last_heard: last, count: count}) do
    {score_text, score_color} = score_display(score)

    ~MOB"""
    <Box background={@panel} fill_width={true} padding={1}>
      <Row fill_width={true} padding={:space_md} background={@panel}>
        <Box background={score_color} width={11} height={11} corner_radius={0} />
        <Spacer size={11} />
        <Column>
          <Text text={format_freq(freq)} text_size={:md} text_color={:on_surface} />
          <Text text={"#{count} obs · #{ago(last)}"} text_size={:sm} text_color={:muted} />
        </Column>
        <Spacer weight={1} />
        <Text text={score_text} text_size={:md} text_color={score_color} />
      </Row>
    </Box>
    """
  end

  # -- Stations -------------------------------------------------------------

  defp station_section([]) do
    empty_box("NO STATIONS HEARD YET")
  end

  defp station_section(stations) do
    rows = Enum.map(stations, &station_row/1)

    ~MOB"""
    <Column background={@bezel} fill_width={true}>
      {rows}
    </Column>
    """
  end

  defp station_row(station) do
    {score_text, score_color} = score_display(station.score)

    ~MOB"""
    <Box background={@panel} fill_width={true} padding={1}>
      <Row fill_width={true} padding={:space_md} background={@panel}>
        <Box background={score_color} width={11} height={11} corner_radius={0} />
        <Spacer size={11} />
        <Column>
          <Text text={station_label(station)} text_size={:md} text_color={:on_surface} />
          <Text text={station_detail(station)} text_size={:sm} text_color={:muted} />
        </Column>
        <Spacer weight={1} />
        <Text text={score_text} text_size={:md} text_color={score_color} />
      </Row>
    </Box>
    """
  end

  # -- Shared bits ----------------------------------------------------------

  defp refresh_row do
    ~MOB"""
    <Box
      background={@inset}
      border_color={@bezel}
      border_width={1}
      corner_radius={0}
      padding={:space_md}
      on_tap={{self(), :lqa_refresh}}
    >
      <Text text="↻ REFRESH" text_size={:sm} text_color={@amber} />
    </Box>
    """
  end

  defp empty_box(msg) do
    ~MOB"""
    <Box
      background={@inset}
      border_color={@bezel}
      border_width={1}
      corner_radius={0}
      padding={:space_md}
      fill_width={true}
    >
      <Text text={msg} text_size={:sm} text_color={:muted} />
    </Box>
    """
  end

  defp status_line(nil),
    do: ~MOB"""
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

  defp header_label(%{ale_net: %{name: name}}) when is_binary(name), do: String.upcase(name)
  defp header_label(_), do: "NO NET"

  # LQA score → {"NN", color}. Green >= 70, amber >= 40, red > 0, muted when
  # there's no score yet.
  defp score_display(nil), do: {"—", @bezel}

  defp score_display(score) when is_number(score) do
    text = score |> round() |> Integer.to_string()

    color =
      cond do
        score >= 70 -> @green
        score >= 40 -> @amber
        score > 0 -> @red
        true -> @muted_amber
      end

    {text, color}
  end

  defp station_label(%{addr: addr, name: name}) when is_binary(name) and name != "" do
    "#{name}  ·  " <> addr_hex(addr)
  end

  defp station_label(%{addr: addr}), do: addr_hex(addr)

  defp station_detail(station) do
    dirs =
      case station.directions do
        [] -> "—"
        ds -> ds |> Enum.map(&String.upcase/1) |> Enum.join("/")
      end

    "#{dirs} · #{snr_text(station.snr_db)} · #{station.count} obs · #{ago(station.last_heard)}"
  end

  defp snr_text(nil), do: "SNR —"
  defp snr_text(snr) when is_number(snr), do: "SNR #{round(snr)}dB"

  defp addr_hex(addr) when is_integer(addr), do: "0x" <> Integer.to_string(addr, 16)
  defp addr_hex(_), do: "0x?"

  defp format_freq(hz) when is_integer(hz) and hz >= 1_000_000 do
    "#{Float.round(hz / 1_000_000, 3)} MHz"
  end

  defp format_freq(hz) when is_integer(hz), do: "#{hz} Hz"
  defp format_freq(_), do: "—"

  # Relative "time ago" from a DateTime, coarse-grained for a status readout.
  defp ago(nil), do: "never"

  defp ago(%DateTime{} = dt) do
    secs = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      secs < 5 -> "now"
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
