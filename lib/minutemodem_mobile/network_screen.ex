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
  alias MinutemodemMobile.Schemas.Network

  @amber 0xFFE8C84A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A
  @green 0xFF33C24A
  @active_bg 0xFF0E1A0E
  @disabled 0xFF555555
  @red 0xFFD24A4A

  # tTLC quantum (Table G-II: tTLC = n × 13.33 ms).
  @tlc_unit 13.33

  # Render-only module: ShellScreen owns mount/state/events and calls
  # render/1 with the needed assigns. mount/3 kept minimal for the behaviour.
  def mount(_params, _session, socket), do: {:ok, socket}

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
          {param_fields(assigns.net.type, assigns.params, assigns[:channels] || [])}
          {status_line(assigns.status)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  defp param_fields("ale", params, channels) do
    generation = Map.get(params, "generation", Network.default_generation())
    scan_mode = Map.get(params, "scan_timing", "sync")

    ~MOB"""
    <Column fill_width={true}>
      {generation_selector(generation)}
      <Spacer size={14} />
      {segmented("ALE WAVEFORM (ALL PDUs)", "ale_waveform",
        [{"DEEP", "deep"}, {"FAST", "fast"}], Map.get(params, "ale_waveform", "deep"))}
      <Spacer size={14} />
      {hex_field("SELF ADDRESS (WALE ADDR)", "self_addr", params)}
      <Spacer size={20} />
      <Divider color={:border} />
      <Spacer size={16} />
      {channels_section(channels)}
      <Spacer size={20} />
      <Divider color={:border} />
      <Spacer size={16} />
      <Text text="SOUNDING (ONE-WAY LQA)" text_size={:sm} text_color={@amber} />
      <Spacer size={12} />
      {segmented("PERIODIC SOUNDING", "sounding_enabled", [{"ON", "on"}, {"OFF", "off"}], Map.get(params, "sounding_enabled", "off"))}
      <Spacer size={6} />
      <Text text="Beacons an LSU_Status on each channel while scanning (LBT first)." text_size={:sm} text_color={:muted} padding={4} />
      <Spacer size={12} />
      {field("SOUNDING INTERVAL (S)", "sounding_interval", Map.get(params, "sounding_interval", ""), "300")}
      <Spacer size={20} />
      <Divider color={:border} />
      <Spacer size={16} />
      <Text text="SCAN TIMING" text_size={:sm} text_color={@amber} />
      <Spacer size={12} />
      {segmented("MODE", "scan_timing", [{"SYNC", "sync"}, {"ASYNC", "async"}], scan_mode)}
      <Spacer size={6} />
      <Text text={scan_timing_hint(scan_mode)} text_size={:sm} text_color={:muted} padding={4} />
      <Spacer size={12} />
      {scan_dwell_control(scan_mode, params)}
      <Spacer size={20} />
      <Divider color={:border} />
      <Spacer size={16} />
      {inp_timing_group(params)}
      <Spacer size={20} />
      <Divider color={:border} />
      <Spacer size={16} />
      <Text text="NET CONTROL" text_size={:sm} text_color={@amber} />
      <Spacer size={12} />
      {net_control_field(params)}
      <Spacer size={20} />
      <Divider color={:border} />
      <Spacer size={16} />
      <Text text="LQA POLICY" text_size={:sm} text_color={@amber} />
      <Spacer size={12} />
      {segmented("MODE", "lqa_mode", MinutemodemMobile.LQAPolicy.mode_options(),
        Map.get(params, "lqa_mode", MinutemodemMobile.LQAPolicy.default_mode()))}
      <Spacer size={6} />
      <Text text={lqa_mode_hint(Map.get(params, "lqa_mode", MinutemodemMobile.LQAPolicy.default_mode()))} text_size={:sm} text_color={:muted} padding={4} />
    </Column>
    """
  end

  # One-line explanation of the currently-selected scan-timing mode.
  defp scan_timing_hint("async"),
    do: "FREE-RUNNING — CALLER SENDS A LONGER SCANNING CALL; NO CLOCK NEEDED"

  defp scan_timing_hint(_),
    do: "LOCKSTEP — ALL STATIONS DWELL TOGETHER (NEEDS GNSS/TOD; AUTO-DEGRADES TO ASYNC IF CLOCK LOST)"

  # Dwell control depends on scan mode (188-141D G.4.1.2):
  #   * sync  → Synchronous Dwell Speed per Table G-I (D is fixed at 1350/SDS)
  #   * async → Minimum Dwell Time INP (free ms)
  defp scan_dwell_control("async", params) do
    field("MINIMUM DWELL (MS)", "scan_dwell_ms", Map.get(params, "scan_dwell_ms", ""), "500")
  end

  defp scan_dwell_control(_sync, params) do
    sds = Map.get(params, "scan_sds", "1")

    ~MOB"""
    <Column fill_width={true}>
      {segmented("SYNC DWELL SPEED (SDS)", "scan_sds", [{"SDS 1", "1"}, {"SDS 2", "2"}, {"SDS 3", "3"}], sds)}
      <Spacer size={6} />
      <Text text={sds_hint(sds)} text_size={:sm} text_color={:muted} padding={4} />
    </Column>
    """
  end

  # Table G-I: D = 1350 ms / SDS.
  defp sds_hint("1"), do: "D = 1350 ms — mixed 3G/4G, scans at 3G speed"
  defp sds_hint("2"), do: "D = 675 ms — supports Fast + Deep WALE"
  defp sds_hint("3"), do: "D = 450 ms — high-speed data, Fast WALE only"
  defp sds_hint(_), do: ""

  # tTLC field with a live "snaps to n × 13.33 ms" readout. The operator types
  # freely; the effective value used by the Link is snapped to the nearest valid
  # multiple (in ShellScreen.inp_opts), and this hint shows what it will become.
  defp tlc_field(params) do
    raw = Map.get(params, "t_tlc", "")

    ~MOB"""
    <Column fill_width={true}>
      <Text text="TLC SETTLING — tTLC" text_size={:sm} text_color={:muted} />
      <Spacer size={4} />
      <TextField
        value={raw}
        placeholder="13.33"
        keyboard={:default}
        return_key={:done}
        on_change={{self(), {:param_change, "t_tlc"}}}
        on_blur={{self(), {:tlc_snap}}}
      />
      <Spacer size={4} />
      <Text text={tlc_snap_hint(raw)} text_size={:sm} text_color={:muted} padding={4} />
    </Column>
    """
  end

  defp tlc_snap_hint(raw) do
    case parse_number(raw) do
      nil ->
        "n × 13.33 ms (blank = 13.33 default)"

      v when v > 0 ->
        n = max(round(v / @tlc_unit), 1)
        "→ snaps to #{Float.round(n * @tlc_unit, 2)} ms (#{n} × 13.33)"

      _ ->
        "n × 13.33 ms"
    end
  end

  # Net Control PU: a 16-bit WALE hex address. The field validates live —
  # normalizes valid input to 0xNNNN (green), or shows a red alert on a non-hex
  # character or an out-of-range value.
  defp net_control_field(params), do: hex_field("NET CONTROL PU (WALE ADDR)", "net_control_pu", params)

  # A 16-bit WALE hex address field (Self Address, Net Control PU). Live-validates
  # to 0xNNNN (green) or a red alert; snaps the value to canonical form on blur
  # via {:hex_snap, key} (handled in ShellScreen).
  defp hex_field(label, key, params) do
    raw = Map.get(params, key, "")
    {msg, color} = hex_validate(raw)

    ~MOB"""
    <Column fill_width={true}>
      <Text text={label} text_size={:sm} text_color={:muted} />
      <Spacer size={4} />
      <TextField
        value={raw}
        placeholder="0x0000"
        keyboard={:default}
        return_key={:done}
        on_change={{self(), {:param_change, key}}}
        on_blur={{self(), {:hex_snap, key}}}
      />
      <Spacer size={4} />
      <Text text={msg} text_size={:sm} text_color={color} padding={4} />
    </Column>
    """
  end

  defp hex_validate(raw) do
    s =
      raw
      |> to_string()
      |> String.trim()
      |> String.replace_prefix("0x", "")
      |> String.replace_prefix("0X", "")

    cond do
      s == "" ->
        {"16-bit WALE address (blank = 0x0000)", @disabled}

      not Regex.match?(~r/^[0-9a-fA-F]+$/, s) ->
        {"⚠ INVALID HEX — only 0-9, A-F (optionally 0x-prefixed)", @red}

      String.length(s) > 4 ->
        {"⚠ OUT OF RANGE — 16-bit max is 0xFFFF", @red}

      true ->
        {"→ 0x" <> String.pad_leading(String.upcase(s), 4, "0"), @green}
    end
  end

  # Parse a numeric field value (integer or float like 13.33); nil if blank/bad.
  defp parse_number(v) do
    s = String.trim(to_string(v))

    cond do
      s == "" -> nil
      match?({_, ""}, Integer.parse(s)) -> elem(Integer.parse(s), 0)
      match?({_, ""}, Float.parse(s)) -> elem(Float.parse(s), 0)
      true -> nil
    end
  end

  # Configurable timing INPs (188-141D Table G-II). Each field persists to net
  # params under its Link key; blank means "use the spec default." Placeholders
  # show the Table G-II defaults.
  defp inp_timing_group(params) do
    ~MOB"""
    <Column fill_width={true}>
      <Text text="INP TIMING (188-141D TABLE G-II)" text_size={:sm} text_color={@amber} />
      <Spacer size={4} />
      <Text text="Blank = spec default. Values in ms." text_size={:sm} text_color={:muted} padding={2} />
      <Spacer size={12} />
      {field("LISTEN BEFORE TX — tLBT", "t_lbt", Map.get(params, "t_lbt", ""), "400")}
      <Spacer size={10} />
      {field("LISTEN BEFORE RESPOND — tLBR", "t_lbr", Map.get(params, "t_lbr", ""), "400")}
      <Spacer size={10} />
      {tlc_field(params)}
      <Spacer size={10} />
      {field("TUNE TIME — ttune", "t_tune", Map.get(params, "t_tune", ""), "40")}
      <Spacer size={10} />
      {field("TIME UNCERTAINTY — tsync", "t_sync", Map.get(params, "t_sync", ""), "36")}
      <Spacer size={10} />
      {field("WAIT RESPONSE — tresponse", "t_response", Map.get(params, "t_response", ""), "2000")}
      <Spacer size={10} />
      {field("WAIT TRAFFIC — ttraffic", "t_traffic", Map.get(params, "t_traffic", ""), "10000")}
      <Spacer size={10} />
      {field("ACTIVITY TIMEOUT — tactivity", "t_activity", Map.get(params, "t_activity", ""), "30000")}
    </Column>
    """
  end

  # One-line explanation of the currently-selected LQA mode.
  defp lqa_mode_hint("off"), do: "LQA DISABLED"
  defp lqa_mode_hint("rx_only"), do: "PASSIVE — RECORD INBOUND, TRANSMIT NOTHING (EMCON-FRIENDLY)"
  defp lqa_mode_hint("tx_only"), do: "BEACON — REPORT SNR + SOUND, DON'T RECORD"
  defp lqa_mode_hint("two_way"), do: "FULL — RECORD INBOUND + REPORT + RECORD PEER SNR"
  defp lqa_mode_hint(_), do: ""

  # Reusable segmented selector: a label over a row of mutually-exclusive
  # cells. `options` is a list of `{label, value}`; the selected value is
  # highlighted. Tapping a cell persists via the generic `{:set_param, key,
  # value}` event (handled in ShellScreen). Reused by every enum-valued net
  # param (waveform, LQA mode, ACS cold-start, sounding strategy, …).
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

  # ALE generation selector. 4G is live; 3G/2G are shown disabled (defined for
  # the roadmap but no link FSM yet). Selecting persists params.generation.
  defp generation_selector(current) do
    ~MOB"""
    <Column fill_width={true}>
      <Text text="GENERATION" text_size={:sm} text_color={:muted} />
      <Spacer size={4} />
      <Row fill_width={true}>
        {gen_button("4G", "4g", current, true)}
        <Spacer size={8} />
        {gen_button("3G", "3g", current, false)}
        <Spacer size={8} />
        {gen_button("2G", "2g", current, false)}
      </Row>
      <Spacer size={4} />
      {gen_note(current)}
    </Column>
    """
  end

  # An enabled, selectable generation cell.
  defp gen_button(label, value, current, true) do
    selected = value == current
    bg = if selected, do: @active_bg, else: @inset
    border = if selected, do: @green, else: @bezel
    text_color = if selected, do: @green, else: @amber
    tag = {self(), {:set_generation, value}}

    ~MOB"""
    <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={tag}>
      <Text text={label} text_size={:md} text_color={text_color} />
    </Box>
    """
  end

  # A disabled generation cell (not yet implemented). No on_tap.
  defp gen_button(label, _value, _current, false) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1}>
      <Text text={label} text_size={:md} text_color={@disabled} />
    </Box>
    """
  end

  defp gen_note("4g"), do: ~MOB"""
  <Text text="188-141D 4G — ACTIVE" text_size={:sm} text_color={:muted} padding={4} />
  """
  defp gen_note(_), do: ~MOB"""
  <Text text="3G / 2G NOT YET SUPPORTED" text_size={:sm} text_color={0xFFB5862A} padding={4} />
  """

  defp param_fields("data", params, _channels) do
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

  defp param_fields(_unknown, _params, _channels) do
    ~MOB"""
    <Text text="UNKNOWN NETWORK TYPE" text_size={:sm} text_color={:muted} />
    """
  end

  # ── Channel plan editor ────────────────────────────────────────────────────
  # The network's structured channel set. Each row is an element (freq, name,
  # mode, role, enabled), edited in place. Roles: HAILING (scanned for link
  # setup), TRAFFIC (data after link), NONE (parked). Persisted via channel_*
  # events handled in ShellScreen.

  defp channels_section(channels) do
    ~MOB"""
    <Column fill_width={true}>
      <Text text="CHANNELS" text_size={:sm} text_color={@amber} />
      <Spacer size={4} />
      <Text text="HAILING = scanned for link setup · TRAFFIC = data after link" text_size={:sm} text_color={:muted} padding={2} />
      <Spacer size={10} />
      {channel_rows(channels)}
      <Spacer size={10} />
      <Box background={@active_bg} border_color={@green} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} on_tap={{self(), {:channel_add}}}>
        <Text text="+ ADD CHANNEL" text_size={:md} text_color={@green} />
      </Box>
    </Column>
    """
  end

  defp channel_rows([]) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Text text="NO CHANNELS — TAP + ADD" text_size={:sm} text_color={:muted} />
    </Box>
    """
  end

  defp channel_rows(channels) do
    cards =
      channels
      |> Enum.map(&channel_card/1)
      |> Enum.intersperse(~MOB"""
      <Spacer size={10} />
      """)

    ~MOB"""
    <Column fill_width={true}>
      {cards}
    </Column>
    """
  end

  defp channel_card(ch) do
    id = ch.id
    freq = if ch.freq_hz, do: to_string(ch.freq_hz), else: ""

    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Column fill_width={true}>
        <Row fill_width={true}>
          <Column fill_width={true} weight={2}>
            <Text text="FREQ (HZ)" text_size={:sm} text_color={:muted} />
            <Spacer size={2} />
            <TextField value={freq} placeholder="7102000" keyboard={:number_pad} return_key={:done} on_change={{self(), {:channel_field, {id, "freq_hz"}}}} />
          </Column>
          <Spacer size={10} />
          <Column fill_width={true} weight={2}>
            <Text text="NAME" text_size={:sm} text_color={:muted} />
            <Spacer size={2} />
            <TextField value={ch.name || ""} placeholder="label" keyboard={:default} return_key={:done} on_change={{self(), {:channel_field, {id, "name"}}}} />
          </Column>
        </Row>
        <Spacer size={10} />
        <Text text="ROLE" text_size={:sm} text_color={:muted} />
        <Spacer size={2} />
        <Row fill_width={true}>
          {chan_role_button("HAILING", "hailing", ch)}
          <Spacer size={6} />
          {chan_role_button("TRAFFIC", "traffic", ch)}
          <Spacer size={6} />
          {chan_role_button("NONE", "none", ch)}
        </Row>
        <Spacer size={10} />
        <Row fill_width={true}>
          <Column fill_width={true} weight={3}>
            <Text text="MODE" text_size={:sm} text_color={:muted} />
            <Spacer size={2} />
            <Row fill_width={true}>
              {chan_mode_button("USB", "usb", ch)}
              <Spacer size={6} />
              {chan_mode_button("LSB", "lsb", ch)}
              <Spacer size={6} />
              {chan_mode_button("DIG", "digital", ch)}
            </Row>
          </Column>
          <Spacer size={10} />
          {chan_enabled_button(ch)}
          <Spacer size={6} />
          {chan_delete_button(ch)}
        </Row>
      </Column>
    </Box>
    """
  end

  defp chan_role_button(label, value, ch) do
    selected = (ch.role || "none") == value
    bg = if selected, do: @active_bg, else: @inset
    border = if selected, do: @green, else: @bezel
    color = if selected, do: @green, else: @amber

    ~MOB"""
    <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={{self(), {:channel_role, {ch.id, value}}}}>
      <Text text={label} text_size={:sm} text_color={color} />
    </Box>
    """
  end

  defp chan_mode_button(label, value, ch) do
    selected = (ch.mode || "usb") == value
    bg = if selected, do: @active_bg, else: @inset
    border = if selected, do: @green, else: @bezel
    color = if selected, do: @green, else: @amber

    ~MOB"""
    <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={{self(), {:channel_mode, {ch.id, value}}}}>
      <Text text={label} text_size={:sm} text_color={color} />
    </Box>
    """
  end

  defp chan_enabled_button(ch) do
    on = ch.enabled != false
    bg = if on, do: @active_bg, else: @inset
    border = if on, do: @green, else: @bezel
    color = if on, do: @green, else: @disabled
    label = if on, do: "ON", else: "OFF"

    ~MOB"""
    <Column>
      <Text text="EN" text_size={:sm} text_color={:muted} />
      <Spacer size={2} />
      <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} on_tap={{self(), {:channel_toggle, ch.id}}}>
        <Text text={label} text_size={:sm} text_color={color} />
      </Box>
    </Column>
    """
  end

  defp chan_delete_button(ch) do
    ~MOB"""
    <Column>
      <Text text=" " text_size={:sm} text_color={:muted} />
      <Spacer size={2} />
      <Box background={@inset} border_color={0xFFD24A4A} border_width={1} corner_radius={0} padding={:space_md} on_tap={{self(), {:channel_delete, ch.id}}}>
        <Text text="DEL" text_size={:sm} text_color={0xFFD24A4A} />
      </Box>
    </Column>
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

  defp type_banner("ale"), do: "ALE NETWORK PARAMETERS"
  defp type_banner("data"), do: "DATA NETWORK PARAMETERS"
  defp type_banner(_), do: "PARAMETERS"
end
