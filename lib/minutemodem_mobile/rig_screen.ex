defmodule MinutemodemMobile.RigScreen do
  @moduledoc """
  RIG — unified rig-management view.

  Render-only (like Config/Network/Linking): `ShellScreen` owns the state and
  events and calls `render/1` with the assigns below. This is the single place
  the operator brings the radio up and sees its live state. There is no
  "release rig" concept — the app owns the unified audio + serial sessions and
  its own data modes, so the rig is never handed back to a separate control
  app. INIT brings the radio fully online; DEINIT takes it down.

  ## What INIT does

  One control, two authorities, together:

    * **CAT** — opens the Hamlib state machine
      (`MinutemodemMobile.Rig.HamlibStateMachine.open/1`): frequency + mode
      control over the rig.
    * **Session** — starts the physical DigiRig session
      (`MinutemodemMobile.Modem.Manager.start_session/2`): USB enumerate →
      permission → CP2102 serial → USB PCM audio.

  DEINIT runs the inverse (`stop_session` + `close`).

  ## Assigns

    * `:usb_present`   — true when a DigiRig CP2102 is enumerated on the USB bus
                          (live, independent of INIT)
    * `:cat_state`     — Hamlib SM state atom (:closed, :opening, :open, :error)
    * `:cat_freq`      — current frequency in Hz, or nil
    * `:cat_mode`      — current mode atom (:usb, :lsb, :digital, …), or nil
    * `:session_state` — Manager status atom (:idle, :opening, :ready, :tx, :unavailable)
    * `:session_tx`    — true when the Manager is keyed (TX active)
    * `:active_name`   — active network name, or nil
    * `:status`        — shared status-line text
  """
  use Mob.Screen

  @amber 0xFFE8C84A
  @panel 0xFF0A0A0A
  @inset 0xFF060606
  @bezel 0xFF3A3A3A
  @green 0xFF33C24A
  @active_bg 0xFF0E1A0E
  @red 0xFFD24A4A
  @disabled 0xFF555555

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background}>
        <Row background={:surface} padding={:space_md} fill_width={true}>
          <Text text="RIG" text_size={:lg} text_color={:on_surface} />
          <Spacer weight={1} />
          <Text text={header_net(assigns)} text_size={:sm} text_color={@amber} />
        </Row>

        <Column background={:background} padding={:space_lg}>
          {subtab_switch(assigns)}
          <Spacer size={16} />
          {body(assigns)}
        </Column>
      </Column>
    </Scroll>
    """
  end

  # -- Subtab switch: STATUS vs CAT OPTIONS ----------------------------------

  defp subtab_switch(assigns) do
    cur = assigns[:rig_subtab] || "status"

    ~MOB"""
    <Row fill_width={true}>
      {subtab_btn("STATUS", "status", cur)}
      <Spacer size={8} />
      {subtab_btn("CAT OPTIONS", "options", cur)}
    </Row>
    """
  end

  defp subtab_btn(label, value, cur) do
    selected = value == cur
    bg = if selected, do: @active_bg, else: @inset
    border = if selected, do: @green, else: @bezel
    color = if selected, do: @green, else: @amber

    ~MOB"""
    <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={{self(), {:rig_subtab, value}}}>
      <Text text={label} text_size={:md} text_color={color} />
    </Box>
    """
  end

  defp body(%{rig_subtab: "options"} = assigns), do: cat_options_body(assigns)
  defp body(%{rig_subtab: "model_picker"} = assigns), do: model_picker_body(assigns)
  defp body(assigns), do: status_body(assigns)

  # -- STATUS body (bring-up + live rig state) -------------------------------

  defp status_body(assigns) do
    ~MOB"""
    <Column fill_width={true}>
      {detect_panel(assigns)}
      <Spacer size={14} />
      {init_panel(assigns)}
      <Spacer size={18} />
      {init_control(assigns)}
      <Spacer size={20} />
      <Divider color={:border} />
      <Spacer size={20} />

      {cat_panel(assigns)}
      <Spacer size={16} />
      {session_panel(assigns)}

      {status_line(assigns.status)}
    </Column>
    """
  end

  # -- CAT OPTIONS body (Hamlib connection settings) -------------------------

  defp cat_options_body(assigns) do
    cfg = assigns[:rig_cfg] || %{}

    ~MOB"""
    <Column fill_width={true}>
      <Text text="CAT OPTIONS" text_size={:sm} text_color={@amber} />
      <Spacer size={4} />
      <Text text="Applied on SAVE — CAT closes and reopens with the new params." text_size={:sm} text_color={:muted} padding={2} />
      <Spacer size={14} />

      {model_row(assigns)}
      <Spacer size={14} />

      {opt_seg("TRANSPORT", "transport", [{"USB", "usb"}, {"NETWORK", "network"}], Map.get(cfg, "transport", "usb"))}
      <Spacer size={14} />
      {opt_field("PATHNAME", "pathname", Map.get(cfg, "pathname", ""), "android-usb:0:0")}
      <Spacer size={14} />

      {opt_seg("BAUD", "serial_speed", [{"4800", "4800"}, {"9600", "9600"}, {"19200", "19200"}, {"38400", "38400"}], Map.get(cfg, "serial_speed", "19200"))}
      <Spacer size={14} />

      {opt_field("CI-V ADDRESS (OPTIONAL)", "civaddr", Map.get(cfg, "civaddr", ""), "e.g. 0x4E")}
      <Spacer size={14} />

      {opt_seg("PTT TYPE", "ptt_type", [{"RTS", "RTS"}, {"DTR", "DTR"}, {"CI-V", "RIG"}, {"NONE", "NONE"}], Map.get(cfg, "ptt_type", "RTS"))}
      <Spacer size={20} />

      {button("SAVE & APPLY", {:rig_cat_save}, @green, @panel)}

      {status_line(assigns.status)}
    </Column>
    """
  end

  defp opt_field(label, key, value, placeholder) do
    ~MOB"""
    <Column fill_width={true}>
      <Text text={label} text_size={:sm} text_color={:muted} />
      <Spacer size={4} />
      <TextField value={to_string(value)} placeholder={placeholder} keyboard={:default} return_key={:done} on_change={{self(), {:rig_cfg_field, key}}} />
    </Column>
    """
  end

  defp opt_seg(label, key, options, current) do
    cells =
      options
      |> Enum.map(fn {text, value} -> opt_seg_cell(text, key, value, current) end)
      |> Enum.intersperse(~MOB"""
      <Spacer size={6} />
      """)

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

  defp opt_seg_cell(text, key, value, current) do
    selected = to_string(value) == to_string(current)
    bg = if selected, do: @active_bg, else: @inset
    border = if selected, do: @green, else: @bezel
    color = if selected, do: @green, else: @amber

    ~MOB"""
    <Box background={bg} border_color={border} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} weight={1} on_tap={{self(), {:rig_cfg_set, {key, value}}}}>
      <Text text={text} text_size={:sm} text_color={color} />
    </Box>
    """
  end

  # -- Rig model row + picker (Hamlib model-by-name selection) ---------------

  # The model as a tappable row instead of a raw number field: shows the
  # resolved "Mfg Model" (when the model list is loaded) plus the Hamlib #, and
  # opens the searchable picker on tap.
  defp model_row(assigns) do
    cfg = assigns[:rig_cfg] || %{}
    id = Map.get(cfg, "model", "")
    models = assigns[:rig_models] || []
    name = model_name(models, id)

    ~MOB"""
    <Column fill_width={true}>
      <Text text="RIG MODEL" text_size={:sm} text_color={:muted} />
      <Spacer size={4} />
      <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} on_tap={{self(), {:rig_model_open}}}>
        <Row fill_width={true}>
          <Column weight={1}>
            <Text text={name} text_size={:md} text_color={@amber} />
            <Spacer size={2} />
            <Text text={"Hamlib ##{id} · tap to change"} text_size={:sm} text_color={@bezel} />
          </Column>
          <Text text="▸" text_size={:md} text_color={@amber} />
        </Row>
      </Box>
    </Column>
    """
  end

  # -- Model picker body (search field + filtered scrollable list) -----------

  defp model_picker_body(assigns) do
    models = assigns[:rig_models] || []
    q = assigns[:model_query] || ""
    matches = filter_models(models, q)

    ~MOB"""
    <Column fill_width={true}>
      <Row fill_width={true}>
        <Text text="SELECT RIG MODEL" text_size={:sm} text_color={@amber} />
        <Spacer weight={1} />
        <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_sm} width={96} on_tap={{self(), {:rig_subtab, "options"}}}>
          <Text text="CANCEL" text_size={:sm} text_color={@amber} />
        </Box>
      </Row>
      <Spacer size={4} />
      <Text text={"#{length(models)} rigs in Hamlib · search by make or model"} text_size={:sm} text_color={:muted} />
      <Spacer size={12} />
      <TextField value={q} placeholder="e.g. IC-706 or Icom" keyboard={:default} return_key={:search} on_change={{self(), {:rig_model_query}}} />
      <Spacer size={12} />
      {model_results(matches, q, length(models))}
    </Column>
    """
  end

  defp model_results(_matches, "", _total) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_lg} fill_width={true}>
      <Text text="Type a manufacturer or model to search." text_size={:sm} text_color={:muted} />
    </Box>
    """
  end

  defp model_results([], _q, _total) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_lg} fill_width={true}>
      <Text text="No matching rigs." text_size={:sm} text_color={:muted} />
    </Box>
    """
  end

  defp model_results(matches, _q, _total) do
    {shown, extra} = {Enum.take(matches, 40), max(length(matches) - 40, 0)}

    rows = Enum.map(shown, &model_result_row/1)

    footer =
      if extra > 0 do
        ~MOB"""
        <Text text={"+#{extra} more — refine your search"} text_size={:sm} text_color={@bezel} padding={6} />
        """
      else
        ~MOB"""
        <Spacer size={0} />
        """
      end

    ~MOB"""
    <Column fill_width={true}>
      {rows}
      {footer}
    </Column>
    """
  end

  defp model_result_row({id, mfg, name, _status}) do
    ~MOB"""
    <Column fill_width={true}>
      <Box background={@panel} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} on_tap={{self(), {:rig_model_pick, id}}}>
        <Row fill_width={true}>
          <Column weight={1}>
            <Text text={"#{mfg} #{name}"} text_size={:md} text_color={@amber} />
            <Spacer size={2} />
            <Text text={"Hamlib ##{id}"} text_size={:sm} text_color={@bezel} />
          </Column>
          <Text text="›" text_size={:md} text_color={@green} />
        </Row>
      </Box>
      <Spacer size={6} />
    </Column>
    """
  end

  # Resolve a model id to "Mfg Model" using the loaded list; fall back to the
  # bare number when the list isn't loaded or the id isn't found.
  defp model_name(_models, ""), do: "— no model set —"

  defp model_name(models, id) do
    idi = to_int(id)

    case Enum.find(models, fn {mid, _, _, _} -> mid == idi end) do
      {_mid, mfg, name, _} -> "#{mfg} #{name}"
      _ -> "Model #{id}"
    end
  end

  # Case-insensitive substring match across "mfg name #id". Sorted by mfg then
  # model name so results read like a catalog.
  defp filter_models(models, q) do
    needle = q |> String.trim() |> String.downcase()

    models
    |> Enum.filter(fn {id, mfg, name, _} ->
      String.contains?(String.downcase("#{mfg} #{name} ##{id}"), needle)
    end)
    |> Enum.sort_by(fn {_id, mfg, name, _} -> {String.downcase(mfg), String.downcase(name)} end)
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> -1
    end
  end

  defp to_int(_), do: -1

  # -- USB detection panel (live, independent of INIT) ----------------------

  # Real-time "is the DigiRig on the bus?" indicator. Polled by ShellScreen
  # every second while this tab is active (USB enumeration only — no session,
  # no permission dialog), so the operator gets a green light the moment the
  # DigiRig is plugged in, before ever pressing INIT.
  defp detect_panel(assigns) do
    {label, color, detail} = detect_display(assigns)

    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Row fill_width={true}>
        <Box background={color} width={13} height={13} corner_radius={0} />
        <Spacer size={12} />
        <Column>
          <Text text={label} text_size={:md} text_color={color} />
          <Spacer size={4} />
          <Text text={detail} text_size={:sm} text_color={:muted} />
        </Column>
      </Row>
    </Box>
    """
  end

  # Green once a CP2102 is enumerated, or whenever a session is already up (in
  # which case the hardware is necessarily present even if a poll hasn't landed).
  defp detect_display(%{usb_present: true}),
    do: {"DIGIRIG DETECTED", @green, "CP2102 on USB — ready to INIT"}

  defp detect_display(%{session_state: s}) when s in [:ready, :tx, :opening],
    do: {"DIGIRIG DETECTED", @green, "Session active"}

  defp detect_display(_),
    do: {"NO DIGIRIG", @disabled, "Connect the DigiRig to the USB-C port"}

  # -- Combined INIT state panel --------------------------------------------

  defp init_panel(assigns) do
    {label, color} = init_display(assigns)

    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_lg} fill_width={true}>
      <Row fill_width={true}>
        <Box background={color} width={13} height={13} corner_radius={0} />
        <Spacer size={12} />
        <Column>
          <Text text={label} text_size={:lg} text_color={color} />
          <Spacer size={4} />
          <Text text={init_detail(assigns)} text_size={:sm} text_color={:muted} />
        </Column>
      </Row>
    </Box>
    """
  end

  # -- INIT / DEINIT control ------------------------------------------------

  # Online (both up) → DEINIT. Fully offline → INIT. Mid-transition → disabled.
  defp init_control(%{cat_state: cat, session_state: sess})
       when cat == :open and sess in [:ready, :tx] do
    button("DEINIT", {:rig_deinit}, @red, @active_bg)
  end

  defp init_control(%{cat_state: cat, session_state: sess})
       when cat in [:opening] or sess in [:opening] do
    disabled_button("WORKING…")
  end

  defp init_control(_assigns) do
    button("INIT", {:rig_init}, @green, @panel)
  end

  # -- CAT panel ------------------------------------------------------------

  defp cat_panel(assigns) do
    {label, color} = cat_display(assigns.cat_state)

    ~MOB"""
    <Box background={@panel} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Column fill_width={true}>
        <Row fill_width={true}>
          <Text text="CAT" text_size={:sm} text_color={:muted} />
          <Spacer weight={1} />
          <Text text={label} text_size={:sm} text_color={color} />
        </Row>
        <Spacer size={8} />
        <Row fill_width={true}>
          <Text text="FREQ" text_size={:sm} text_color={@bezel} />
          <Spacer size={10} />
          <Text text={format_freq(assigns.cat_freq)} text_size={:md} text_color={@amber} />
          <Spacer weight={1} />
          <Text text="MODE" text_size={:sm} text_color={@bezel} />
          <Spacer size={10} />
          <Text text={format_mode(assigns.cat_mode)} text_size={:md} text_color={@amber} />
        </Row>
      </Column>
    </Box>
    """
  end

  # -- Session panel --------------------------------------------------------

  defp session_panel(assigns) do
    {label, color} = session_display(assigns.session_state)

    ~MOB"""
    <Box background={@panel} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Column fill_width={true}>
        <Row fill_width={true}>
          <Text text="SESSION" text_size={:sm} text_color={:muted} />
          <Spacer weight={1} />
          <Text text={label} text_size={:sm} text_color={color} />
        </Row>
        <Spacer size={8} />
        <Row fill_width={true}>
          <Text text="DIGIRIG" text_size={:sm} text_color={@bezel} />
          <Spacer size={10} />
          <Text text={digirig_line(assigns.session_state)} text_size={:md} text_color={@amber} />
          <Spacer weight={1} />
          {tx_indicator(assigns.session_tx)}
        </Row>
      </Column>
    </Box>
    """
  end

  defp tx_indicator(true) do
    ~MOB"""
    <Row>
      <Box background={@red} width={11} height={11} corner_radius={0} />
      <Spacer size={8} />
      <Text text="TX" text_size={:md} text_color={@red} />
    </Row>
    """
  end

  defp tx_indicator(_), do: ~MOB"""
  <Text text="RX" text_size={:md} text_color={@green} />
  """

  # -- Shared button helpers (LinkingScreen idiom) --------------------------

  defp button(label, tag, text_color, bg) do
    ~MOB"""
    <Box background={bg} border_color={text_color} border_width={1} corner_radius={0} padding={:space_md} fill_width={true} on_tap={{self(), tag}}>
      <Text text={label} text_size={:md} text_color={text_color} />
    </Box>
    """
  end

  defp disabled_button(label) do
    ~MOB"""
    <Box background={@inset} border_color={@bezel} border_width={1} corner_radius={0} padding={:space_md} fill_width={true}>
      <Text text={label} text_size={:md} text_color={@disabled} />
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

  # -- Display mapping ------------------------------------------------------

  defp header_net(%{active_name: nil}), do: "NO NETWORK"
  defp header_net(%{active_name: name}), do: String.upcase(name)

  # Combined INIT state: both authorities up = ONLINE; both down = OFFLINE;
  # anything in between is a partial/transitional state worth surfacing.
  defp init_display(%{cat_state: :open, session_state: sess}) when sess in [:ready, :tx],
    do: {"ONLINE", @green}

  defp init_display(%{cat_state: :error}), do: {"CAT ERROR", @red}
  defp init_display(%{session_state: :unavailable}), do: {"SESSION ERROR", @red}

  defp init_display(%{cat_state: :closed, session_state: s}) when s in [:idle, :unavailable],
    do: {"OFFLINE", @amber}

  defp init_display(_), do: {"PARTIAL", @amber}

  defp init_detail(%{cat_state: cat, session_state: sess}) do
    "CAT " <> (cat |> to_string() |> String.upcase()) <>
      "   ·   SESSION " <> (sess |> to_string() |> String.upcase())
  end

  defp cat_display(:open), do: {"OPEN", @green}
  defp cat_display(:opening), do: {"OPENING", @amber}
  defp cat_display(:error), do: {"ERROR", @red}
  defp cat_display(_), do: {"CLOSED", @amber}

  defp session_display(:ready), do: {"READY", @green}
  defp session_display(:tx), do: {"TX", @red}
  defp session_display(:opening), do: {"OPENING", @amber}
  defp session_display(:unavailable), do: {"UNAVAILABLE", @red}
  defp session_display(_), do: {"IDLE", @amber}

  defp digirig_line(:ready), do: "CONNECTED"
  defp digirig_line(:tx), do: "CONNECTED"
  defp digirig_line(:opening), do: "OPENING…"
  defp digirig_line(:unavailable), do: "—"
  defp digirig_line(_), do: "NOT OPEN"

  defp format_freq(nil), do: "——"

  defp format_freq(hz) when is_integer(hz) and hz >= 1_000_000 do
    mhz = Float.round(hz / 1_000_000, 3)
    "#{mhz} MHz"
  end

  defp format_freq(hz) when is_integer(hz), do: "#{hz} Hz"
  defp format_freq(_), do: "——"

  defp format_mode(nil), do: "———"
  defp format_mode(mode), do: mode |> to_string() |> String.upcase()
end
