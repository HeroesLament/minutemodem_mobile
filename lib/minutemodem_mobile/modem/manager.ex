defmodule MinutemodemMobile.Modem.Manager do
  @moduledoc """
  Owns the physical half-duplex modem session for a single DigiRig.

  This is the policy-free *mechanism* layer that sits under minutewave's
  protocol stack. It holds the two hardware sessions for one rig — the USB
  PCM audio stream (`MinutemodemMobile.AudioPcm`, CM108 codec) and the
  CP2102 serial line (`MinutemodemMobile.Cp2102`, RTS = PTT) — and exposes
  them to minutewave through two thin behaviour adapters:

    * `MinutemodemMobile.Audio.UsbPcmBackend` (`Minutewave.Audio.Backend`)
    * `MinutemodemMobile.Rig.Cp2102Control` (`Minutewave.Rig.Control.Behaviour`)

  Both adapters delegate here. The Manager is the single process the AudioPcm
  and VendorUsb NIFs deliver their async messages to (they deliver to the
  *calling* process, so every NIF call that arms a delivery runs from this
  GenServer).

  ## Single rig, single session

  OTG USB hubs are not reliably supported on Android, so this is deliberately
  a one-rig design: one DigiRig on the USB-C port, one audio stream, one
  serial session. The `rig_id` is fixed at start.

  ## The half-duplex T/R gate (the reason this layer exists)

  A DigiRig is physically half-duplex: keying PTT (RTS high) puts the radio
  into transmit, and while keyed the CM108 capture side is hearing our own
  sidetone or garbage — it must *not* be fed to the demodulator as a received
  signal. So this layer enforces:

      acquire_tx  ->  RTS high  +  tx_active := true   (RX delivery gated off)
      release_tx  ->  RTS low   +  tx_active := false  (RX delivery restored)

  While `tx_active` is true the Manager drops every `{:audio_pcm, :data, …}`
  frame and swallows `:stream_silent` (which is *expected* during TX, not a
  fault — see `MinutemodemMobile.AudioPcm`). This is mechanism only; the
  protocol-level decision of *whether* TX may start (vs. an active RX) is made
  above by `Minutewave.Modem.Arbiter`. The two never fight: the Arbiter gates
  the FSMs, the Manager gates the wire.

  ## RX delivery

  After `open`, captured PCM arrives as `{:audio_pcm, :data, session, bin}`
  where `bin` is s16le interleaved. When the gate is open the Manager forwards
  it **verbatim** (zero-copy binary, no list conversion) to every RX
  subscriber as `{:rx_audio, rig_id, bin}`. Subscribers (RxFSM) hand the
  binary straight to `unified_demod_symbols_bin`. No per-sample work touches
  the BEAM on this path.

  ## TX drain

  `play_tx/2` enqueues s16le PCM to the AudioTrack via `AudioPcm.write`, which
  is non-blocking and emits no completion event. To know when the audio has
  actually played out (so the protocol layer can release PTT), the Manager
  arms a duration timer: `frames / sample_rate` seconds plus a tail margin,
  after which it sends `:tx_complete` to the rig's TxFSM.

  > v2: replace the duration timer with a real write-queue-drained signal from
  > the bridge once `MobBridge` exposes one. The timer is a correct first cut
  > (it can only unkey *too late*, never too early) but it is open-loop.

  ## Lifecycle

  The Manager does **not** start a hardware session on boot. Keying a
  transmitter with no rig attached — and triggering a USB permission dialog
  the user didn't ask for — is the wrong default. A session is started
  deliberately via `start_session/2`, which runs
  enumerate → request_permission → open(serial) → enable → set_baud →
  open(audio). Until then the Manager is idle and adapter TX/RX calls return
  `{:error, :no_session}` or are no-ops.
  """

  use GenServer
  require Logger

  alias MinutemodemMobile.{AudioPcm, Cp2102}
  alias Mob.VendorUsb

  @sample_rate 48_000
  @channels 1
  # Tail margin added to the computed playout duration before signalling drain,
  # covering AudioTrack buffering + RTS round-trip latency.
  @tx_tail_ms 120
  # Bounded backoff bounds for re-opening a dead audio stream.
  @reopen_backoff_ms 500
  @reopen_backoff_max_ms 8_000

  defstruct [
    :rig_id,
    # :idle | :opening | :ready | :tx
    status: :idle,
    serial_session: nil,
    serial_device: nil,
    audio_session: nil,
    # RX subscribers: %{pid => true}
    subscribers: %{},
    # Half-duplex gate. When true, drop captured PCM + swallow stream_silent.
    tx_active: false,
    # rig TX owner tag (Control.acquire_tx bookkeeping)
    tx_owner: nil,
    # timer ref for the open-loop TX drain
    tx_drain_timer: nil,
    # rig CAT state (placeholder until real CAT freq/mode lands)
    frequency: 14_100_000,
    mode: :usb,
    reopen_backoff: @reopen_backoff_ms,
    # the GenServer.from awaiting an in-progress start_session/2, if any
    start_waiter: nil,
    # Does this Manager own the CP2102 serial line? True for the Cp2102Control
    # backend (Manager opens the serial line and keys RTS = PTT itself). False
    # for the HamlibControl backend, where Hamlib owns the CP2102 for CAT and
    # keys PTT via ptt_type=RTS — the Manager then runs audio-only and never
    # opens/claims the serial interface (see own_serial_from_config/0).
    own_serial?: true,
    # Live "is a DigiRig CP2102 on the USB bus?" flag, maintained by a passive
    # enumeration probe (see :probe_usb) so the UI can show detection before any
    # session is started. Enumeration only — never opens/claims the device.
    usb_present: false
  ]

  # Passive USB-presence probe cadence (ms). Cheap enumeration; only armed while
  # idle (a live session already implies the device is present).
  @usb_probe_ms 2_000

  # ==========================================================================
  # Public API
  # ==========================================================================

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenServer.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {Minutewave.Rig.InstanceRegistry, {rig_id, :modem_manager}}}
  end

  @doc """
  Open the physical session: enumerate the DigiRig, request USB permission
  (pops a system dialog on first grant), open + configure the CP2102 serial
  line, then open the pinned USB PCM audio stream.

  Blocks until the session is ready or fails. Returns `{:ok, info}` or
  `{:error, reason}`.
  """
  @spec start_session(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(rig_id, opts \\ []) do
    GenServer.call(via(rig_id), {:start_session, opts}, 45_000)
  end

  @doc "Tear down the audio + serial sessions and return to idle."
  @spec stop_session(term()) :: :ok
  def stop_session(rig_id), do: GenServer.call(via(rig_id), :stop_session)

  @doc "Current Manager status map (for UI / diagnostics)."
  @spec status(term()) :: map()
  def status(rig_id), do: GenServer.call(via(rig_id), :status)

  # ---- Minutewave.Audio.Backend surface (called by UsbPcmBackend) ----------

  @doc false
  def subscribe(rig_id, pid), do: GenServer.call(via(rig_id), {:subscribe, pid})
  @doc false
  def unsubscribe(rig_id, pid), do: GenServer.call(via(rig_id), {:unsubscribe, pid})
  @doc false
  def play_tx(rig_id, samples), do: GenServer.cast(via(rig_id), {:play_tx, samples})
  @doc false
  def tx_active?(rig_id), do: GenServer.call(via(rig_id), :tx_active?)

  # ---- Minutewave.Rig.Control.Behaviour surface (called by Cp2102Control) ---

  @doc false
  def acquire_tx(rig_id, tag), do: GenServer.call(via(rig_id), {:acquire_tx, tag})
  @doc false
  def release_tx(rig_id, tag), do: GenServer.call(via(rig_id), {:release_tx, tag})
  @doc false
  def get_frequency(rig_id), do: GenServer.call(via(rig_id), :get_frequency)
  @doc false
  def set_frequency(rig_id, hz), do: GenServer.call(via(rig_id), {:set_frequency, hz})
  @doc false
  def get_mode(rig_id), do: GenServer.call(via(rig_id), :get_mode)
  @doc false
  def set_mode(rig_id, mode), do: GenServer.call(via(rig_id), {:set_mode, mode})
  @doc false
  def rig_status(rig_id), do: GenServer.call(via(rig_id), :rig_status)

  # ==========================================================================
  # GenServer
  # ==========================================================================

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    Logger.metadata(rig: String.slice(to_string(rig_id), 0, 8))
    own_serial? = own_serial_from_config()

    unless own_serial? do
      Logger.info("[Manager] Hamlib backend active — running audio-only (Hamlib owns CP2102 CAT+PTT)")
    end

    # Begin passive USB-presence probing so the UI can reflect a plugged-in
    # DigiRig before any session is started.
    schedule_usb_probe()

    {:ok, %__MODULE__{rig_id: rig_id, subscribers: %{}, own_serial?: own_serial?}}
  end

  # The Manager owns the CP2102 serial line unless the HamlibControl backend is
  # selected — in which case Hamlib owns it (CAT + RTS PTT via the android-usb
  # bridge) and the Manager must not open/claim the same interface.
  defp own_serial_from_config do
    Application.get_env(:minutewave, :rig_control) != MinutemodemMobile.Rig.HamlibControl
  end

  # ---- session lifecycle ---------------------------------------------------

  @impl true
  def handle_call({:start_session, _opts}, _from, %{status: :ready} = state) do
    {:reply, {:ok, session_info(state)}, state}
  end

  def handle_call({:start_session, _opts}, from, %{status: :idle} = state) do
    # Kick off enumeration; the rest proceeds as VendorUsb async events land in
    # handle_info. We hold `from` and reply once audio is open (or on error).
    VendorUsb.list_devices(sock(), vendor_id: Cp2102.vid())
    {:noreply, %{state | status: :opening, start_waiter: from}}
  end

  def handle_call({:start_session, _opts}, _from, state) do
    {:reply, {:error, {:busy, state.status}}, state}
  end

  def handle_call(:stop_session, _from, state) do
    {:reply, :ok, %{do_teardown(state) | status: :idle}}
  end

  def handle_call(:status, _from, state) do
    {:reply, session_info(state), state}
  end

  # ---- audio backend -------------------------------------------------------

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, true)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_call(:tx_active?, _from, state) do
    {:reply, state.tx_active, state}
  end

  # ---- rig control: TX acquire / release (the T/R gate) --------------------

  def handle_call({:acquire_tx, _tag}, _from, %{status: status} = state)
      when status not in [:ready, :tx] do
    {:reply, {:error, :no_session}, state}
  end

  def handle_call({:acquire_tx, tag}, _from, %{tx_owner: nil} = state) do
    # Mechanism: key PTT (RTS high) and close the RX gate.
    key_ptt(state)
    {:reply, :ok, %{state | tx_active: true, tx_owner: tag, status: :tx}}
  end

  def handle_call({:acquire_tx, _tag}, _from, %{tx_owner: current} = state) do
    {:reply, {:error, {:busy, current}}, state}
  end

  def handle_call({:release_tx, _tag}, _from, state) do
    {:reply, :ok, do_release_tx(state)}
  end

  # ---- rig control: CAT (placeholders until real CAT lands) ----------------

  def handle_call(:get_frequency, _from, state),
    do: {:reply, {:ok, state.frequency}, state}

  def handle_call({:set_frequency, hz}, _from, state),
    do: {:reply, :ok, %{state | frequency: hz}}

  def handle_call(:get_mode, _from, state),
    do: {:reply, {:ok, state.mode}, state}

  def handle_call({:set_mode, mode}, _from, state),
    do: {:reply, :ok, %{state | mode: mode}}

  def handle_call(:rig_status, _from, state) do
    {:reply,
     {:ok,
      %{
        frequency: state.frequency,
        mode: state.mode,
        tx_active?: state.tx_active,
        tx_owner: state.tx_owner
      }}, state}
  end

  # ---- TX audio ------------------------------------------------------------

  @impl true
  def handle_cast({:play_tx, _samples}, %{audio_session: nil} = state) do
    Logger.warning("[Manager] play_tx with no audio session; dropping")
    {:noreply, state}
  end

  def handle_cast({:play_tx, samples}, state) do
    bin = IO.iodata_to_binary(samples)
    AudioPcm.write(sock(), state.audio_session, bin)

    # Arm the open-loop drain timer. duration = frames / sample_rate, where
    # frames = bytes / 2 (s16) / channels.
    frames = div(byte_size(bin), 2 * @channels)
    play_ms = div(frames * 1000, @sample_rate) + @tx_tail_ms

    state = cancel_drain_timer(state)
    timer = Process.send_after(self(), :tx_drained, play_ms)
    {:noreply, %{state | tx_drain_timer: timer}}
  end

  # ==========================================================================
  # handle_info: NIF async events + timers
  # ==========================================================================

  # VendorUsb: normalize then dispatch the open sequence.
  @impl true
  def handle_info({:peripheral, :vendor_usb, _, _, _} = raw, state) do
    handle_vendor_usb(VendorUsb.normalize_message(raw), state)
  end

  # AudioPcm RX hot path: drop while keyed, else forward the binary verbatim.
  def handle_info({:audio_pcm, :data, session, bin}, %{audio_session: session} = state) do
    if state.tx_active do
      {:noreply, state}
    else
      for {pid, _} <- state.subscribers, do: send(pid, {:rx_audio, state.rig_id, bin})
      {:noreply, state}
    end
  end

  # AudioPcm facts (devices/opened/route/silent/error) via normalize_message.
  def handle_info({:mob_file_result, "audio_pcm", _, _} = raw, state) do
    handle_audio_pcm(AudioPcm.normalize_message(raw), state)
  end

  def handle_info({:audio_pcm, _, _} = raw, state) do
    handle_audio_pcm(AudioPcm.normalize_message(raw), state)
  end

  # TX drain timer fired: signal the TxFSM so it completes its cycle.
  def handle_info(:tx_drained, %{tx_owner: nil} = state) do
    {:noreply, %{state | tx_drain_timer: nil}}
  end

  def handle_info(:tx_drained, state) do
    notify_tx_complete(state)
    {:noreply, %{state | tx_drain_timer: nil}}
  end

  def handle_info(:reopen_audio, state) do
    {:noreply, open_audio(state)}
  end

  # RECORD_AUDIO granted — now actually open the DigiRig capture stream. The
  # subsequent {:audio_pcm, :opened|:error} event finishes the start_session
  # reply via handle_audio_pcm.
  def handle_info({:permission, :microphone, :granted}, state) do
    {:noreply, do_open_audio(state)}
  end

  # RECORD_AUDIO denied — the capture stream can't open, so fail the in-progress
  # start_session with a clear reason (the RIG panel surfaces it).
  def handle_info({:permission, :microphone, :denied}, state) do
    Logger.warning("[Manager] microphone (RECORD_AUDIO) denied; cannot open audio session")

    if state.status == :opening do
      fail_start(state, :microphone_permission_denied)
    else
      {:noreply, state}
    end
  end

  # Passive USB-presence probe. While idle, arm an enumeration (the result lands
  # in handle_vendor_usb/:devices and sets usb_present). While a session is up
  # or opening, the device is necessarily present, so skip the enumeration and
  # mark present directly. Always reschedules.
  def handle_info(:probe_usb, %{status: :idle} = state) do
    _ =
      try do
        VendorUsb.list_devices(sock(), vendor_id: Cp2102.vid())
      catch
        _, _ -> :ok
      end

    schedule_usb_probe()
    {:noreply, state}
  end

  def handle_info(:probe_usb, state) do
    schedule_usb_probe()
    {:noreply, %{state | usb_present: true}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ==========================================================================
  # VendorUsb event handling (the open sequence)
  # ==========================================================================

  # Start-of-session enumeration (status :opening): request permission on the
  # first DigiRig found, or fail the start if none is present.
  defp handle_vendor_usb({:peripheral, :vendor_usb, :devices, _, devices}, %{status: :opening} = state) do
    case devices do
      [dev | _] ->
        VendorUsb.request_permission(sock(), dev)
        {:noreply, %{state | serial_device: dev, usb_present: true}}

      [] ->
        fail_start(%{state | usb_present: false}, :no_digirig)
    end
  end

  # Passive probe enumeration (any non-opening state): update presence only,
  # never request permission or otherwise touch the device.
  defp handle_vendor_usb({:peripheral, :vendor_usb, :devices, _, devices}, state) do
    present = devices != []

    if present != state.usb_present do
      Logger.info("[Manager] DigiRig #{if present, do: "detected", else: "removed"} (usb probe)")
    end

    {:noreply, %{state | usb_present: present}}
  end

  defp handle_vendor_usb({:peripheral, :vendor_usb, :permission_granted, _, dev}, %{own_serial?: true} = state) do
    VendorUsb.open(sock(), dev, interface: 0)
    {:noreply, %{state | serial_device: dev}}
  end

  defp handle_vendor_usb({:peripheral, :vendor_usb, :permission_granted, _, dev}, state) do
    # Audio-only (Hamlib backend): we enumerated + requested permission only so
    # Hamlib's android-usb bridge can later claim the CP2102 for CAT+PTT. The
    # Manager does not open/claim the serial line; proceed straight to audio.
    # serial_session stays nil, so key_ptt/unkey_ptt are no-ops (Hamlib keys PTT).
    {:noreply, open_audio(%{state | serial_device: dev})}
  end

  defp handle_vendor_usb({:peripheral, :vendor_usb, :permission_denied, _, _dev}, state) do
    fail_start(state, :permission_denied)
  end

  defp handle_vendor_usb({:peripheral, :vendor_usb, :opened, session, _dev}, state) do
    # Serial open; configure UART, then open audio.
    Cp2102.enable(sock(), session)
    Cp2102.set_baud(sock(), session, 115_200)
    {:noreply, open_audio(%{state | serial_session: session})}
  end

  defp handle_vendor_usb({:peripheral, :vendor_usb, :control_result, _session, _payload}, state) do
    # Acks for enable/set_baud/set_rts. Success is implicit.
    {:noreply, state}
  end

  defp handle_vendor_usb({:peripheral, :vendor_usb, :error, _session, reason}, state) do
    Logger.warning("[Manager] vendor_usb error: #{inspect(reason)}")

    if state.status == :opening do
      fail_start(state, {:serial_error, reason})
    else
      {:noreply, state}
    end
  end

  defp handle_vendor_usb({:peripheral, :vendor_usb, :disconnected, _session, _reason}, state) do
    Logger.warning("[Manager] DigiRig disconnected")
    {:noreply, %{do_teardown(state) | status: :idle}}
  end

  defp handle_vendor_usb(_other, state), do: {:noreply, state}

  # ==========================================================================
  # AudioPcm event handling
  # ==========================================================================

  defp handle_audio_pcm({:audio_pcm, :opened, info}, state) do
    Logger.info("[Manager] audio opened: #{inspect(info)}")

    state = %{
      state
      | audio_session: info.session,
        status: :ready,
        reopen_backoff: @reopen_backoff_ms
    }

    {:noreply, reply_start(state, {:ok, session_info(state)})}
  end

  defp handle_audio_pcm({:audio_pcm, :error, reason}, state) do
    Logger.warning("[Manager] audio error: #{inspect(reason)}")

    cond do
      state.status == :opening ->
        fail_start(state, {:audio_error, reason})

      reason == :dead ->
        backoff = min(state.reopen_backoff, @reopen_backoff_max_ms)
        Process.send_after(self(), :reopen_audio, backoff)
        {:noreply, %{state | audio_session: nil, reopen_backoff: backoff * 2}}

      true ->
        {:noreply, state}
    end
  end

  defp handle_audio_pcm({:audio_pcm, :error, reason, _session}, state) do
    handle_audio_pcm({:audio_pcm, :error, reason}, state)
  end

  defp handle_audio_pcm({:audio_pcm, :stream_silent, _session}, state) do
    # Expected while keyed (capture suppressed by the gate); a fact otherwise.
    # Mechanism only logs; recovery policy belongs above. Never carrier loss.
    unless state.tx_active, do: Logger.debug("[Manager] capture stream silent (RX)")
    {:noreply, state}
  end

  defp handle_audio_pcm({:audio_pcm, :stream_active, _session}, state) do
    {:noreply, state}
  end

  defp handle_audio_pcm({:audio_pcm, :route_changed, info}, state) do
    Logger.info("[Manager] audio route_changed: #{inspect(info)}")
    {:noreply, state}
  end

  defp handle_audio_pcm({:audio_pcm, :write_overflow, dropped}, state) do
    Logger.warning("[Manager] TX write overflow, dropped_total=#{inspect(dropped)}")
    {:noreply, state}
  end

  defp handle_audio_pcm(_other, state), do: {:noreply, state}

  # ==========================================================================
  # Internal helpers
  # ==========================================================================

  # Throwaway socket: the AudioPcm/VendorUsb/Cp2102 wrappers thread a socket
  # only to return it; the meaningful effect is the NIF call, which delivers
  # async results to *this* process. We discard the returned socket.
  defp sock, do: %Mob.Socket{}

  defp schedule_usb_probe, do: Process.send_after(self(), :probe_usb, @usb_probe_ms)

  # Opening the DigiRig capture stream needs Android's RECORD_AUDIO permission.
  # It's declared in the manifest but is a runtime ("dangerous") permission, so
  # a fresh install has it denied and AudioPcm.open fails with :open_failed. We
  # request `:microphone` here (pops the system dialog on first run); the grant
  # arrives async as {:permission, :microphone, _} and do_open_audio runs on
  # :granted. Requesting when already granted resolves immediately with no
  # dialog, so this is safe to call on every open (including :reopen_audio).
  defp open_audio(state) do
    Mob.Permissions.request(sock(), :microphone)
    state
  rescue
    e ->
      # If the permission plugin isn't available, fall back to opening directly
      # (surfaces :open_failed if the grant is genuinely missing).
      Logger.warning("[Manager] microphone permission request failed: #{inspect(e)}")
      do_open_audio(state)
  end

  defp do_open_audio(state) do
    # Pin to the DigiRig. UNPROCESSED (raw) at the codec's native rate; the
    # bridge classifies the USB codec via the semantic is_usb flag. For the
    # single-DigiRig case the default-route open lands on it; explicit
    # device-id pinning (from list_devices ids) is a follow-up.
    AudioPcm.open(sock(),
      sample_rate: @sample_rate,
      channels: @channels,
      processing: :raw
    )

    state
  end

  defp key_ptt(%{serial_session: nil}), do: :ok
  defp key_ptt(%{serial_session: session}), do: Cp2102.set_rts(sock(), session, true) && :ok

  defp unkey_ptt(%{serial_session: nil}), do: :ok
  defp unkey_ptt(%{serial_session: session}), do: Cp2102.set_rts(sock(), session, false) && :ok

  defp do_release_tx(%{tx_owner: nil} = state), do: state

  defp do_release_tx(state) do
    unkey_ptt(state)
    state = cancel_drain_timer(state)
    %{state | tx_active: false, tx_owner: nil, status: ready_status(state)}
  end

  defp ready_status(%{audio_session: nil}), do: :idle
  defp ready_status(_), do: :ready

  defp cancel_drain_timer(%{tx_drain_timer: nil} = state), do: state

  defp cancel_drain_timer(%{tx_drain_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | tx_drain_timer: nil}
  end

  defp notify_tx_complete(state) do
    case GenServer.whereis({:via, Registry, {Minutewave.Modem.Registry, {state.rig_id, :tx}}}) do
      nil -> :ok
      pid -> send(pid, :tx_complete)
    end
  end

  defp do_teardown(state) do
    state = cancel_drain_timer(state)
    if state.serial_session, do: unkey_ptt(state)
    if state.audio_session, do: AudioPcm.close(sock(), state.audio_session)
    if state.serial_session, do: VendorUsb.close(sock(), state.serial_session)

    %{state | audio_session: nil, serial_session: nil, tx_active: false, tx_owner: nil}
  end

  defp fail_start(state, reason) do
    Logger.warning("[Manager] start_session failed: #{inspect(reason)}")
    state = reply_start(%{state | status: :idle}, {:error, reason})
    {:noreply, do_teardown(state)}
  end

  defp reply_start(%{start_waiter: nil} = state, _reply), do: state

  defp reply_start(%{start_waiter: from} = state, reply) do
    GenServer.reply(from, reply)
    %{state | start_waiter: nil}
  end

  defp session_info(state) do
    %{
      rig_id: state.rig_id,
      status: state.status,
      audio_session: state.audio_session,
      serial_session: state.serial_session,
      tx_active: state.tx_active,
      usb_present: state.usb_present,
      sample_rate: @sample_rate
    }
  end
end
