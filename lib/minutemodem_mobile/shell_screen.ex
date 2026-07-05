defmodule MinutemodemMobile.ShellScreen do
  @moduledoc """
  Root screen hosting a bottom TabBar (CONFIG / NETWORK / LINKING). Mob 0.7.5's
  framework-level tab_bar/drawer nav is not wired through the render path, but
  the native renderer DOES handle a `tab_bar` node directly, so we drive the
  tab bar ourselves: this screen owns all state + events for every tab and
  renders each body via `ConfigScreen.render/1`, `NetworkScreen.render/1`, and
  `LinkingScreen.render/1` (pure functions of assigns).

  ## ALE / Linking

  The LINKING tab is operational: it drives `Minutewave.ALE.Link` and reflects
  live link state. This screen joins the ALE `:pg` broadcast group
  `{:minutemodem, :rig, rig_id}` (scope `:minutemodem_pg`) in `mount/3`, so
  `{:ale_state_change, …}` / `{:ale_event, …}` arrive as `handle_info`
  messages and update the live state. Generation (4G/3G/2G) is set in the
  NETWORK view, not here — here it is read-only, and only a 4G ALE net enables
  the controls.
  """
  use Mob.Screen

  alias MinutemodemMobile.{
    Networks,
    Channels,
    NetworkIO,
    Contacts,
    RigConfig,
    ConfigScreen,
    NetworkScreen,
    RigScreen,
    LinkingScreen,
    ContactsScreen,
    LinkQualityScreen,
    LinkQuality,
    NetworkTimeScreen,
    Gnss
  }

  alias Minutewave.Clock

  alias MinutemodemMobile.ALE.Supervisor, as: AleSup
  alias Minutewave.ALE.Link

  @pg_scope :minutemodem_pg

  def mount(_params, _session, socket) do
    rig_id = rig_id()

    # Join the ALE broadcast group so Link/Transmitter state changes and events
    # are delivered to this screen process as plain messages.
    join_ale_group(rig_id)

    socket =
      load(socket,
        active_tab: "config",
        status: nil,
        rig_id: rig_id,
        ale_state: ale_current_state(rig_id),
        ale_info: nil,
        ale_render_mono: 0,
        ale_event: nil,
        call_addr: "",
        lqa_channels: [],
        lqa_stations: [],
        time_status: nil,
        gnss_status: nil,
        selected_contact: nil,
        rig_subtab: "status",
        rig_cfg: rig_cfg_draft(),
        rig_models: [],
        model_query: ""
      )

    # Drive the clock display at ~1 Hz (only re-reads while the TIME tab is up).
    schedule_tick()

    {:ok, socket}
  end

  # Load all state the tab bodies need: Config (station/networks/audio),
  # Network (active net + params), Linking (active ALE net + derived flags).
  defp load(socket, extra) do
    networks = Networks.list()
    active = Enum.find(networks, & &1.active)

    rig_id = socket.assigns[:rig_id] || rig_id()
    {ale_net, ale_generation, ale_supported} = ale_context(active)
    {cat_state, cat_freq, cat_mode} = cat_state(rig_id)
    {session_state, session_tx, usb_present} = session_state(rig_id)

    params = (active && active.params) || %{}
    channels = if active, do: safe_lqa(fn -> Channels.list(active.id) end), else: []
    freqs = channels |> Enum.map(& &1.freq_hz) |> Enum.reject(&is_nil/1)
    lqa_channels = safe_lqa(fn -> LinkQuality.channel_summaries(freqs) end)
    lqa_stations = safe_lqa(fn -> LinkQuality.station_summaries() end)
    time_status = safe_time(fn -> Clock.status() end)
    gnss_status = safe_time(fn -> Gnss.status() end)
    contacts = safe_lqa(fn -> Contacts.list() end)

    socket
    |> Mob.Socket.assign(
      station: Mob.State.get(:station_name, ""),
      audio_backend: audio_backend_name(),
      digirig_status: digirig_status(),
      networks: networks,
      active_name: active && active.name,
      active_type: active && active.type,
      net: active,
      params: params,
      channels: channels,
      # Link Quality tab context
      lqa_channels: lqa_channels,
      lqa_stations: lqa_stations,
      # Network Time tab context
      time_status: time_status,
      gnss_status: gnss_status,
      # Contacts tab context
      contacts: contacts,
      # Linking-tab context
      ale_net: ale_net,
      ale_generation: ale_generation,
      ale_supported: ale_supported,
      ale_running: AleSup.running?(rig_id),
      # Rig-tab context (CAT via Hamlib SM + physical session via Manager)
      cat_state: cat_state,
      cat_freq: cat_freq,
      cat_mode: cat_mode,
      session_state: session_state,
      session_tx: session_tx,
      usb_present: usb_present
    )
    |> Mob.Socket.assign(extra)
  end

  # -- Rig-tab state gathering ----------------------------------------------

  # CAT view from the Hamlib state machine. Returns {state, freq_hz, mode}.
  defp cat_state(rig_id) do
    case MinutemodemMobile.Rig.HamlibStateMachine.status(rig_id) do
      {:ok, %{state: st, frequency: f, mode: m}} -> {st, f, m}
      _ -> {:closed, nil, nil}
    end
  catch
    :exit, _ -> {:closed, nil, nil}
  end

  # Session view from the Manager. Returns {status_atom, tx_active?, usb_present?}.
  defp session_state(rig_id) do
    st = MinutemodemMobile.Modem.Manager.status(rig_id)
    {Map.get(st, :status, :idle), Map.get(st, :tx_active, false), Map.get(st, :usb_present, false)}
  catch
    :exit, _ -> {:unavailable, false, false}
  end

  # Derive the Linking-tab context from the active network. Supported only when
  # the active net is ALE with generation 4g (the only implemented link FSM).
  defp ale_context(nil), do: {nil, nil, false}

  defp ale_context(%{type: "ale", params: params} = net) do
    gen = Map.get(params || %{}, "generation", "4g")
    {net, gen, gen == "4g"}
  end

  defp ale_context(_non_ale), do: {nil, nil, false}

  # -- DigiRig status (Config tab) ------------------------------------------

  defp digirig_status do
    rig_id = rig_id()

    try do
      MinutemodemMobile.Modem.Manager.status(rig_id).status
    catch
      :exit, _ -> :unavailable
    end
  end

  defp audio_backend_name do
    case Application.get_env(:minutewave, :audio_backend) do
      nil -> "NONE"
      mod -> mod |> Module.split() |> List.last() |> String.upcase()
    end
  end

  # -- Render ---------------------------------------------------------------

  def render(assigns) do
    ~MOB"""
    <Drawer
      active={assigns.active_tab}
      tabs={[
        %{id: "config", label: "CONFIG", icon: "settings"},
        %{id: "network", label: "NETWORK", icon: "list"},
        %{id: "rig", label: "RIG", icon: "radio"},
        %{id: "linking", label: "LINKING", icon: "link"},
        %{id: "contacts", label: "CONTACTS", icon: "person"},
        %{id: "quality", label: "QUALITY", icon: "insights"},
        %{id: "time", label: "TIME", icon: "schedule"}
      ]}
      on_tab_select={{self(), :tab_selected}}
    >
      {tab_body("config", assigns, &ConfigScreen.render/1)}
      {tab_body("network", assigns, &NetworkScreen.render/1)}
      {tab_body("rig", assigns, &RigScreen.render/1)}
      {tab_body("linking", assigns, &LinkingScreen.render/1)}
      {tab_body("contacts", assigns, &ContactsScreen.render/1)}
      {tab_body("quality", assigns, &LinkQualityScreen.render/1)}
      {tab_body("time", assigns, &NetworkTimeScreen.render/1)}
    </Drawer>
    """
  end

  # Render only the ACTIVE tab's body; inactive tabs get a near-empty
  # placeholder. Mob's Drawer holds all seven tab children at once, so rendering
  # every screen on every frame built a ~2 MB tree per render — at scan's ~1 Hz
  # re-render cadence that outran ART's GC and OOM-killed the app. These screens
  # are render-only (no per-tab state to preserve), so collapsing the inactive
  # ones is free and cuts render size ~10x. Switching tabs re-renders with the
  # newly-active body, as it already did.
  defp tab_body(id, %{active_tab: id} = assigns, render_fn), do: render_fn.(assigns)

  defp tab_body(_id, _assigns, _render_fn) do
    ~MOB"""
    <Column></Column>
    """
  end

  # -- Tab switching --------------------------------------------------------

  def handle_info({:change, :tab_selected, tab_id}, socket) do
    socket = Mob.Socket.assign(socket, active_tab: tab_id)
    # Refresh LQA summaries when the operator switches to the QUALITY tab, so
    # it reflects observations recorded since the last load.
    socket = if tab_id in ["quality", "time"], do: load(socket, []), else: socket
    {:noreply, socket}
  end

  # -- Config tab events ----------------------------------------------------

  def handle_info({:change, :station_changed, value}, socket) do
    Mob.State.put(:station_name, value)
    {:noreply, Mob.Socket.assign(socket, station: value)}
  end

  def handle_info({:tap, {:activate, name}}, socket) do
    net = Enum.find(socket.assigns.networks, &(&1.name == name))

    case net && Networks.activate(net.id) do
      {:ok, _} ->
        {:noreply, load(socket, status: "ACTIVATED " <> name)}

      _ ->
        {:noreply, Mob.Socket.assign(socket, status: "ACTIVATE FAILED")}
    end
  end

  # -- Network import / export (Config tab) ---------------------------------

  # Open the OS document picker; the result arrives as {:files, :picked, _}.
  def handle_info({:tap, {:net_import}}, socket) do
    Mob.Files.pick(%Mob.Socket{}, types: ["json", {:mime, "application/json"}])
    {:noreply, Mob.Socket.assign(socket, status: "CHOOSE A NETWORK JSON FILE…")}
  end

  # Export the active network as JSON via the OS share sheet.
  def handle_info({:tap, {:net_export}}, socket) do
    case socket.assigns.net do
      nil ->
        {:noreply, Mob.Socket.assign(socket, status: "NO ACTIVE NETWORK TO EXPORT")}

      net ->
        json = NetworkIO.export_json(net)
        Mob.Share.text(%Mob.Socket{}, json)
        {:noreply, Mob.Socket.assign(socket, status: "EXPORTED " <> String.upcase(net.name))}
    end
  end

  def handle_info({:files, :picked, [%{path: path} | _]}, socket) do
    socket =
      case File.read(path) do
        {:ok, json} ->
          case NetworkIO.import_json(json) do
            {:ok, net} -> load(socket, status: "IMPORTED " <> String.upcase(net.name))
            {:error, reason} -> Mob.Socket.assign(socket, status: import_error(reason))
          end

        {:error, _} ->
          Mob.Socket.assign(socket, status: "COULD NOT READ FILE")
      end

    {:noreply, socket}
  end

  def handle_info({:files, :picked, _}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "NO FILE SELECTED")}
  end

  def handle_info({:files, :cancelled}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "IMPORT CANCELLED")}
  end

  def handle_info({:tap, :new_network}, socket) do
    name = Networks.next_default_name()

    case Networks.create(%{name: name, type: "ale"}) do
      {:ok, _} ->
        {:noreply, load(socket, status: "CREATED " <> name)}

      {:error, _cs} ->
        {:noreply, Mob.Socket.assign(socket, status: "CREATE FAILED")}
    end
  end

  # -- Network tab events ---------------------------------------------------

  def handle_info({:tap, {:set_generation, gen}}, socket) do
    case socket.assigns.net do
      nil ->
        {:noreply, socket}

      net ->
        case Networks.update_params(net, %{"generation" => gen}) do
          {:ok, _updated} ->
            {:noreply, load(socket, status: "GENERATION " <> String.upcase(gen))}

          {:error, _cs} ->
            {:noreply, Mob.Socket.assign(socket, status: "GENERATION NOT SUPPORTED")}
        end
    end
  end

  # Generic enum-param setter for segmented selectors (waveform, LQA mode, ACS
  # cold-start, sounding strategy, …). Persists into the active net's params.
  def handle_info({:tap, {:set_param, {key, value}}}, socket) do
    case socket.assigns.net do
      nil ->
        {:noreply, socket}

      net ->
        case Networks.update_params(net, %{key => value}) do
          {:ok, _updated} ->
            {:noreply, load(socket, status: "SAVED " <> String.upcase(key))}

          {:error, _cs} ->
            {:noreply, Mob.Socket.assign(socket, status: "SAVE FAILED")}
        end
    end
  end

  # -- Channel plan events (Network tab) ------------------------------------

  def handle_info({:tap, {:channel_add}}, socket) do
    case socket.assigns.net do
      nil ->
        {:noreply, socket}

      net ->
        case Channels.add(net.id, %{"mode" => "usb", "role" => "none"}) do
          {:ok, _} -> {:noreply, load(socket, status: "CHANNEL ADDED")}
          {:error, _} -> {:noreply, Mob.Socket.assign(socket, status: "ADD FAILED")}
        end
    end
  end

  def handle_info({:tap, {:channel_delete, id}}, socket) do
    Channels.delete(id)
    {:noreply, load(socket, status: "CHANNEL REMOVED")}
  end

  def handle_info({:tap, {:channel_toggle, id}}, socket) do
    Channels.toggle_enabled(id)
    {:noreply, load(socket, [])}
  end

  def handle_info({:tap, {:channel_role, {id, role}}}, socket) do
    Channels.update(id, %{"role" => role})
    {:noreply, load(socket, [])}
  end

  def handle_info({:tap, {:channel_mode, {id, mode}}}, socket) do
    Channels.update(id, %{"mode" => mode})
    {:noreply, load(socket, [])}
  end

  # Channel text fields (freq/name). freq is coerced to an integer; a blank or
  # non-numeric freq is ignored rather than erroring, so partial edits are safe.
  def handle_info({:change, {:channel_field, {id, "freq_hz"}}, value}, socket) do
    case Integer.parse(String.trim(to_string(value))) do
      {hz, _} -> Channels.update(id, %{"freq_hz" => hz})
      :error -> :ok
    end

    {:noreply, socket}
  end

  def handle_info({:change, {:channel_field, {id, field}}, value}, socket) do
    Channels.update(id, %{field => value})
    {:noreply, socket}
  end

  # -- Contact events (Contacts tab) ----------------------------------------

  def handle_info({:tap, {:contact_add}}, socket) do
    gen = default_contact_gen(socket)
    n = length(socket.assigns[:contacts] || []) + 1

    case Contacts.add(%{"name" => "CONTACT #{n}", "generation" => gen}) do
      {:ok, c} ->
        {:noreply, socket |> load(status: "CONTACT ADDED") |> Mob.Socket.assign(selected_contact: c.id)}

      {:error, _} ->
        {:noreply, Mob.Socket.assign(socket, status: "ADD FAILED")}
    end
  end

  def handle_info({:tap, {:contact_delete, id}}, socket) do
    Contacts.delete(id)
    sel = if socket.assigns[:selected_contact] == id, do: nil, else: socket.assigns[:selected_contact]
    {:noreply, socket |> load(status: "CONTACT REMOVED") |> Mob.Socket.assign(selected_contact: sel)}
  end

  def handle_info({:tap, {:contact_select, id}}, socket) do
    name = case Contacts.get(id) do
      nil -> "?"
      c -> c.name || "?"
    end

    {:noreply, Mob.Socket.assign(socket, selected_contact: id, status: "SELECTED " <> String.upcase(name))}
  end

  def handle_info({:tap, {:contact_gen, {id, gen}}}, socket) do
    Contacts.update(id, %{"generation" => gen})
    {:noreply, load(socket, [])}
  end

  def handle_info({:tap, {:contact_form, {id, form}}}, socket) do
    Contacts.update(id, %{"form_4g" => form})
    {:noreply, load(socket, [])}
  end

  def handle_info({:tap, {:contact_mp, id}}, socket) do
    case Contacts.get(id) do
      nil -> :ok
      c -> Contacts.update(id, %{"multipoint_4g" => not (c.multipoint_4g == true)})
    end

    {:noreply, load(socket, [])}
  end

  # Numeric contact fields: parse; blank/invalid ignored (partial edits safe).
  def handle_info({:change, {:contact_field, {id, field}}, value}, socket)
      when field in ["grp_3g", "mbr_3g", "pdu_4g", "net_4g"] do
    case Integer.parse(String.trim(to_string(value))) do
      {n, _} -> Contacts.update(id, %{field => n})
      :error -> :ok
    end

    {:noreply, socket}
  end

  # String contact fields (name, addr_2g, up_4g).
  def handle_info({:change, {:contact_field, {id, field}}, value}, socket) do
    Contacts.update(id, %{field => value})
    {:noreply, socket}
  end

  def handle_info({:change, {:param_change, key}, value}, socket) do
    case socket.assigns.net do
      nil ->
        {:noreply, socket}

      net ->
        case Networks.update_params(net, %{key => value}) do
          {:ok, _updated} ->
            {:noreply, load(socket, status: "SAVED " <> String.upcase(key))}

          {:error, _cs} ->
            {:noreply, Mob.Socket.assign(socket, status: "SAVE FAILED")}
        end
    end
  end

  # -- Linking tab events ---------------------------------------------------

  def handle_info({:change, :call_addr_changed, value}, socket) do
    {:noreply, Mob.Socket.assign(socket, call_addr: value)}
  end

  # Operator tapped a contact suggestion under the CALL field: hold the contact
  # as the target *by id* (not a copied string) and clear the search text. CALL
  # reads the contact's raw address values directly from the record.
  def handle_info({:tap, {:contact_pick, id}}, socket) do
    case Contacts.get(id) do
      nil ->
        {:noreply, socket}

      c ->
        {:noreply,
         Mob.Socket.assign(socket,
           selected_contact: id,
           call_addr: "",
           status: "TARGET " <> String.upcase(to_string(c.name))
         )}
    end
  end

  # Clear the selected target and return to search/manual entry.
  def handle_info({:tap, {:contact_clear}}, socket) do
    {:noreply, Mob.Socket.assign(socket, selected_contact: nil, call_addr: "", status: "TARGET CLEARED")}
  end

  def handle_info({:tap, {:ale_scan}}, socket) do
    with {:ok, socket} <- ensure_ale_started(socket) do
      rig_id = socket.assigns.rig_id

      case safe_link(fn -> Link.scan(rig_id, scan_opts(socket)) end) do
        :ok ->
          {:noreply, Mob.Socket.assign(socket, status: "SCANNING")}

        {:error, reason} ->
          {:noreply, Mob.Socket.assign(socket, status: "SCAN FAILED: #{inspect(reason)}")}
      end
    else
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_info({:tap, {:ale_stop}}, socket) do
    _ = safe_link(fn -> Link.stop(socket.assigns.rig_id) end)
    {:noreply, Mob.Socket.assign(socket, status: "STOPPED")}
  end

  def handle_info({:tap, {:ale_call}}, socket) do
    with {:ok, socket} <- ensure_ale_started(socket),
         {:ok, dest} <- resolve_call_dest(socket) do
      rig_id = socket.assigns.rig_id

      case safe_link(fn -> Link.call(rig_id, dest, call_opts(socket)) end) do
        :ok ->
          {:noreply,
           Mob.Socket.assign(socket, status: "CALLING 0x#{Integer.to_string(dest, 16)}")}

        {:error, reason} ->
          {:noreply, Mob.Socket.assign(socket, status: "CALL FAILED: #{inspect(reason)}")}
      end
    else
      {:error, :bad_addr} ->
        {:noreply, Mob.Socket.assign(socket, status: "INVALID DEST ADDRESS")}

      {:error, :not_callable} ->
        {:noreply, Mob.Socket.assign(socket, status: "TARGET HAS NO CALLABLE ADDRESS")}

      {:error, socket} when is_map(socket) ->
        {:noreply, socket}
    end
  end

  def handle_info({:tap, {:ale_sound}}, socket) do
    with {:ok, socket} <- ensure_ale_started(socket) do
      _ = safe_link(fn -> Link.sound(socket.assigns.rig_id, []) end)
      {:noreply, Mob.Socket.assign(socket, status: "SOUNDING")}
    else
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_info({:tap, {:ale_terminate}}, socket) do
    _ = safe_link(fn -> Link.terminate_link(socket.assigns.rig_id, :normal) end)
    {:noreply, Mob.Socket.assign(socket, status: "TERMINATING")}
  end

  # -- Rig tab events -------------------------------------------------------

  # INIT: bring the radio fully online — open CAT (Hamlib SM) and start the
  # physical DigiRig session (USB enumerate → permission → serial → audio)
  # together. `start_session/2` blocks until the session is ready or fails
  # (and may pop a USB permission dialog on first grant); the CAT open is
  # quick and independent. Either failing is surfaced in the status line and
  # reflected by the reloaded cat_state/session_state panels.
  def handle_info({:tap, {:rig_init}}, socket) do
    rig_id = socket.assigns.rig_id

    # Start the session FIRST: it enumerates the DigiRig and secures CP2102 USB
    # permission (popping the grant dialog on first run). Hamlib's serial bridge
    # can only claim the CP2102 once permission is held, so CAT must open after.
    sess =
      try do
        MinutemodemMobile.Modem.Manager.start_session(rig_id)
      catch
        :exit, _ -> {:error, :unavailable}
      end

    cat = MinutemodemMobile.Rig.HamlibStateMachine.open(rig_id)

    status =
      case {cat, sess} do
        {:ok, {:ok, _}} -> "RIG ONLINE"
        {:ok, {:error, reason}} -> "CAT OK · SESSION FAILED: #{inspect(reason)}"
        {{:error, c}, {:ok, _}} -> "SESSION OK · CAT FAILED: #{inspect(c)}"
        {{:error, c}, {:error, s}} -> "INIT FAILED: CAT #{inspect(c)} / SESSION #{inspect(s)}"
      end

    {:noreply, load(socket, status: status)}
  end

  # -- CAT Options subtab (Rig tab) -----------------------------------------

  def handle_info({:tap, {:rig_subtab, value}}, socket) do
    # Refresh the draft from persisted config when entering the options subtab.
    socket = if value == "options", do: Mob.Socket.assign(socket, rig_cfg: rig_cfg_draft()), else: socket
    {:noreply, Mob.Socket.assign(socket, rig_subtab: value)}
  end

  def handle_info({:tap, {:rig_cfg_set, {key, value}}}, socket) do
    cfg = Map.put(socket.assigns[:rig_cfg] || %{}, key, value)
    {:noreply, Mob.Socket.assign(socket, rig_cfg: cfg)}
  end

  def handle_info({:change, {:rig_cfg_field, key}, value}, socket) do
    cfg = Map.put(socket.assigns[:rig_cfg] || %{}, key, value)
    {:noreply, Mob.Socket.assign(socket, rig_cfg: cfg)}
  end

  # Open the model picker. Lazily load (and cache) the full Hamlib rig list the
  # first time — it's ~1000 rows so we fetch once and keep it in assigns.
  def handle_info({:tap, {:rig_model_open}}, socket) do
    models =
      case socket.assigns[:rig_models] do
        list when is_list(list) and list != [] -> list
        _ -> load_rig_models()
      end

    {:noreply,
     Mob.Socket.assign(socket, rig_models: models, model_query: "", rig_subtab: "model_picker")}
  end

  def handle_info({:change, {:rig_model_query}, value}, socket) do
    {:noreply, Mob.Socket.assign(socket, model_query: value)}
  end

  # Pick a model: stash its Hamlib number into the draft and return to CAT
  # OPTIONS (draft is preserved — it's saved/applied there with SAVE & APPLY).
  def handle_info({:tap, {:rig_model_pick, id}}, socket) do
    cfg = Map.put(socket.assigns[:rig_cfg] || %{}, "model", to_string(id))
    {:noreply, Mob.Socket.assign(socket, rig_cfg: cfg, rig_subtab: "options")}
  end

  # Persist the CAT config and apply it: update the runtime env and reconfigure
  # the state machine (which closes + reopens CAT with the new model/conf).
  def handle_info({:tap, {:rig_cat_save}}, socket) do
    case RigConfig.update(socket.assigns[:rig_cfg] || %{}) do
      {:ok, config} ->
        {model, conf} = RigConfig.to_hamlib(config)

        Application.put_env(:minutemodem_mobile, MinutemodemMobile.Rig.HamlibStateMachine,
          model: model,
          conf: conf
        )

        _ =
          try do
            MinutemodemMobile.Rig.HamlibStateMachine.reconfigure(socket.assigns.rig_id, model, conf)
          catch
            :exit, _ -> :ok
          end

        {:noreply, Mob.Socket.assign(socket, rig_cfg: rig_cfg_draft(), status: "CAT CONFIG SAVED & APPLIED")}

      {:error, _} ->
        {:noreply, Mob.Socket.assign(socket, status: "SAVE FAILED — CHECK FIELDS")}
    end
  end

  # DEINIT: take the radio down — stop the physical session and close CAT.
  def handle_info({:tap, {:rig_deinit}}, socket) do
    rig_id = socket.assigns.rig_id

    _ =
      try do
        MinutemodemMobile.Modem.Manager.stop_session(rig_id)
      catch
        :exit, _ -> :ok
      end

    _ = MinutemodemMobile.Rig.HamlibStateMachine.close(rig_id)

    {:noreply, load(socket, status: "RIG OFFLINE")}
  end

  # -- Link Quality tab events ----------------------------------------------

  def handle_info({:tap, :lqa_refresh}, socket) do
    {:noreply, load(socket, status: "LQA REFRESHED")}
  end

  # -- Network Time tab events ----------------------------------------------

  def handle_info({:tap, {:set_tod_admissible, bool}}, socket) do
    safe_clock(fn -> Clock.set_tod_admissible(bool) end)
    {:noreply, load(socket, status: if(bool, do: "TOD: NETWORK", else: "TOD: OUTSIDE"))}
  end

  def handle_info({:tap, :time_refresh}, socket) do
    {:noreply, load(socket, status: "TIME REFRESHED")}
  end

  # ~1 Hz clock tick. Only re-reads (and re-renders with) fresh clock/GNSS
  # status while the TIME tab is active, so the UTC readout advances live
  # without running the heavier full reload.
  def handle_info(:tick, socket) do
    rig_id = socket.assigns[:rig_id] || rig_id()

    # Keep the RIG view live: refresh DigiRig USB presence, session, and CAT
    # every second. All synchronous, crash-tolerant reads (no async peripheral
    # messages land in this screen — the Manager owns that).
    {session_state, session_tx, usb_present} = session_state(rig_id)

    # While the ALE Link is driving the radio (scan/call/link), it owns the
    # CI-V bus and hops the VFO ~2 Hz. Polling CAT here would both contend on
    # that bus AND make cat_freq change every tick — forcing a full-screen
    # re-render every second. Sustained, that allocation outran GC and the
    # render heap climbed to an OOM. So suspend the CAT poll while the Link is
    # active and keep the last-known values (they're not meaningful mid-scan).
    {cat_state, cat_freq, cat_mode} =
      if link_driving?(socket.assigns[:ale_state]) do
        {socket.assigns[:cat_state], socket.assigns[:cat_freq], socket.assigns[:cat_mode]}
      else
        cat_state(rig_id)
      end

    time_fields =
      if socket.assigns[:active_tab] == "time" do
        [
          time_status: safe_time(fn -> Clock.status() end),
          gnss_status: safe_time(fn -> Gnss.status() end)
        ]
      else
        []
      end

    # Only re-render when something the operator can see actually changed.
    # An idle tick that produces identical values must NOT re-render — a
    # per-second full-tree re-render is the dominant source of render-heap
    # churn, and skipping the no-op case keeps allocation flat at rest.
    changed? =
      session_state != socket.assigns[:session_state] or
        session_tx != socket.assigns[:session_tx] or
        usb_present != socket.assigns[:usb_present] or
        cat_state != socket.assigns[:cat_state] or
        cat_freq != socket.assigns[:cat_freq] or
        cat_mode != socket.assigns[:cat_mode] or
        time_fields != []

    socket =
      if changed? do
        Mob.Socket.assign(
          socket,
          [
            usb_present: usb_present,
            session_state: session_state,
            session_tx: session_tx,
            cat_state: cat_state,
            cat_freq: cat_freq,
            cat_mode: cat_mode
          ] ++ time_fields
        )
      else
        socket
      end

    schedule_tick()
    {:noreply, socket}
  end

  # -- Live ALE broadcasts (from :pg group) ---------------------------------

  # A running scan broadcasts a state-change on every dwell hop (~2 Hz). Each
  # Mob.Socket.assign forces a full-screen re-render + setRootJson; sustained at
  # 2 Hz (atop the 1 Hz tick) that exhausts the render bridge's heap over a few
  # minutes and the app is OOM-killed. So coalesce: always reflect a genuine
  # state transition (infrequent), but throttle same-state per-hop refreshes to
  # ~1 Hz and skip them entirely when the operator isn't watching the LINKING
  # tab (nothing on-screen depends on the live hop readout there).
  def handle_info({:ale_state_change, _rig_id, state, info}, socket) do
    prev = socket.assigns[:ale_state]
    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:ale_render_mono] || 0
    on_linking = socket.assigns[:active_tab] == "linking"

    cond do
      state != prev ->
        {:noreply,
         Mob.Socket.assign(socket,
           ale_state: state,
           ale_info: info,
           ale_running: true,
           ale_render_mono: now
         )}

      on_linking and now - last >= 1000 ->
        {:noreply, Mob.Socket.assign(socket, ale_info: info, ale_render_mono: now)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:ale_event, _rig_id, event, payload}, socket) do
    {:noreply, Mob.Socket.assign(socket, ale_event: {event, payload})}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- ALE helpers ----------------------------------------------------------

  # Start the ALE stack on demand for the active 4G net, parsing self_addr from
  # the network's params. Returns {:ok, socket} on success, or {:error, socket}
  # with a status set on failure (no active 4G net, missing/invalid self_addr).
  defp ensure_ale_started(socket) do
    rig_id = socket.assigns.rig_id

    cond do
      not socket.assigns.ale_supported ->
        {:error, Mob.Socket.assign(socket, status: "ACTIVE NETWORK IS NOT 4G ALE")}

      AleSup.running?(rig_id) ->
        {:ok, socket}

      true ->
        case parse_addr(Map.get(socket.assigns.params, "self_addr")) do
          {:ok, self_addr} ->
            case AleSup.start_stack(rig_id, self_addr) do
              :ok ->
                {:ok, Mob.Socket.assign(socket, ale_running: true)}

              {:error, reason} ->
                {:error,
                 Mob.Socket.assign(socket, status: "ALE START FAILED: #{inspect(reason)}")}
            end

          {:error, :bad_addr} ->
            {:error, Mob.Socket.assign(socket, status: "SET A VALID SELF ADDRESS IN NETWORK")}
        end
    end
  end

  # Parse a self/dest address from the params text. Accepts decimal ("1001") or
  # hex ("0x3E9"). Returns {:ok, integer} or {:error, :bad_addr}.
  defp parse_addr(nil), do: {:error, :bad_addr}
  defp parse_addr(""), do: {:error, :bad_addr}

  defp parse_addr(s) when is_integer(s), do: {:ok, s}

  defp parse_addr(s) when is_binary(s) do
    s = String.trim(s)

    cond do
      String.starts_with?(s, "0x") or String.starts_with?(s, "0X") ->
        case Integer.parse(String.slice(s, 2..-1//1), 16) do
          {n, ""} -> {:ok, n}
          _ -> {:error, :bad_addr}
        end

      true ->
        case Integer.parse(s) do
          {n, ""} -> {:ok, n}
          _ -> {:error, :bad_addr}
        end
    end
  end

  # Resolve the CALL destination to the integer wire address the ALE stack
  # expects. When a contact target is selected, read its raw address values
  # (Contacts.dest/1) directly; otherwise parse the manually-typed field. A
  # contact that resolves to a non-numeric address (a User Process name with no
  # PDU) is reported as not callable rather than silently coerced.
  defp resolve_call_dest(socket) do
    case selected_contact_struct(socket) do
      nil ->
        parse_addr(socket.assigns.call_addr)

      contact ->
        case Contacts.dest(contact) do
          {:addr, n} -> {:ok, n}
          _ -> {:error, :not_callable}
        end
    end
  end

  defp selected_contact_struct(socket) do
    case socket.assigns[:selected_contact] do
      nil -> nil
      id -> Contacts.get(id)
    end
  end

  # Build scan opts from the active net's structured channel plan: the enabled
  # hailing channels (see Channels.scan_set/1), as maps the ALE scanner expects.
  defp scan_opts(socket) do
    case socket.assigns.net do
      nil ->
        []

      net ->
        chs =
          net.id
          |> Channels.scan_set()
          |> Enum.map(fn c ->
            %{freq_hz: c.freq_hz, name: c.name || "", mode: chan_mode_atom(c.mode)}
          end)

        if chs == [], do: [], else: [channels: chs]
    end
  end

  defp call_opts(socket), do: scan_opts(socket)

  defp chan_mode_atom("lsb"), do: :lsb
  defp chan_mode_atom("am"), do: :am
  defp chan_mode_atom("fm"), do: :fm
  defp chan_mode_atom("cw"), do: :cw
  defp chan_mode_atom("digital"), do: :digital
  defp chan_mode_atom(_), do: :usb

  defp ale_current_state(rig_id) do
    if AleSup.running?(rig_id) do
      case safe_get_state(rig_id) do
        {state, _info} -> state
        _ -> :idle
      end
    else
      :idle
    end
  end

  defp safe_get_state(rig_id) do
    Link.get_state(rig_id)
  catch
    :exit, _ -> :idle
  end

  defp join_ale_group(rig_id) do
    group = {:minutemodem, :rig, rig_id}

    try do
      :pg.join(@pg_scope, group, self())
    catch
      # :pg scope not started yet — broadcasts simply won't reach us until a
      # later mount. Boot starts the scope before screens, so this is defensive.
      _, _ -> :ok
    end
  end

  defp rig_id, do: MinutemodemMobile.Modem.SessionSupervisor.default_rig_id()

  # Run an LQA read, tolerating a not-yet-ready Repo (early boot) or a query
  # error rather than crashing the shell. Empty list is the safe default.
  defp safe_lqa(fun) do
    fun.()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Read Clock/Gnss status, tolerating an unavailable server (nil default).
  defp safe_time(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Map NetworkIO.import_json/1 error reasons to a short status-line message.
  defp import_error({:name_exists, name}), do: "NETWORK '" <> String.upcase(name) <> "' ALREADY EXISTS"
  defp import_error(:invalid_json), do: "INVALID JSON FILE"
  defp import_error(:missing_name), do: "JSON MISSING A 'name'"
  defp import_error({:invalid_network, _}), do: "INVALID NETWORK DATA"
  defp import_error({:invalid_channel, _}), do: "INVALID CHANNEL DATA"
  defp import_error(_), do: "IMPORT FAILED"

  # Default a new contact's generation to the active ALE network's generation,
  # else 4G.
  defp default_contact_gen(socket) do
    case socket.assigns[:net] do
      %{type: "ale", params: params} -> Map.get(params || %{}, "generation", "4g")
      _ -> "4g"
    end
  end

  # Load the persisted CAT config into a string-keyed draft map the CAT Options
  # editor binds to. Tolerant of a not-yet-ready Repo.
  defp rig_cfg_draft do
    case safe_time(fn -> RigConfig.get() end) do
      %MinutemodemMobile.Schemas.RigConfig{} = c ->
        %{
          "model" => to_string(c.model),
          "transport" => c.transport,
          "pathname" => c.pathname,
          "serial_speed" => c.serial_speed,
          "civaddr" => c.civaddr || "",
          "ptt_type" => c.ptt_type
        }

      _ ->
        %{}
    end
  end

  # Fetch the full Hamlib rig catalog via the NIF: [{model, mfg, name, status}].
  # DirtyIo-scheduled in the NIF, so this returns synchronously. Tolerant of a
  # missing/broken NIF (returns []) so the picker degrades to "no rigs".
  defp load_rig_models do
    case Hamlib.Nif.list_models() do
      list when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Run an ALE Link command without letting a callee crash take down the screen.
  # Link.* funcs are blocking `:gen_statem.call(..., :infinity)`; if the Link
  # FSM raises while handling the command, that surfaces here as an `:exit` in
  # this (the caller's) process — which, unguarded, kills the ShellScreen and
  # freezes the whole UI. Trap it and return an `{:error, _}` the caller can
  # render as a status line instead.
  defp safe_link(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:link_unavailable, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  # True while the ALE Link owns the radio (scanning/calling/linked). During
  # these states the app must not poll CAT — the Link is hopping the VFO.
  defp link_driving?(state),
    do: state in [:scanning, :sounding, :lbt, :calling, :lbr, :responding, :linked, :terminating]

  defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)

  defp safe_clock(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end
end
