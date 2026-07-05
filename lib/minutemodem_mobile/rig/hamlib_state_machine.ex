defmodule MinutemodemMobile.Rig.HamlibStateMachine do
  @moduledoc """
  Owns the Hamlib CAT (Computer-Aided Transceiver) lifecycle for a single rig.

  This is the **sole** caller of the `Hamlib` API in the app. It wraps a
  `Hamlib.Rig` process (which itself owns the serial line / NIF handle) in a
  `gen_statem` so the rig's open/closed lifecycle is explicit and recoverable,
  and so CAT calls have one clear owner.

  ## Division of responsibility

  CAT only. Frequency and mode are this machine's job. **PTT is not** — keying
  the transmitter stays with `MinutemodemMobile.Modem.Manager` via the CP2102
  RTS line, so there is exactly one owner of RTS and no contention between
  Hamlib's `set_ptt` and the half-duplex T/R gate. `HamlibControl` composes the
  two: CAT calls land here, TX calls land on the Manager.

  ## States

    * `:closed`  — initialized, no `Hamlib.Rig` process. Boot default. Nothing
      is opened on boot (same deliberate-session principle the Manager
      follows — don't touch hardware, or pop a USB dialog, until asked).
    * `:opening` — starting + opening a `Hamlib.Rig`. Transient.
    * `:open`    — rig live; serves freq/mode get/set.
    * `:error`   — an open or a call failed; bounded-backoff retry re-enters
      `:opening`. The last error is kept in data for `status/1`.

  ## Configuration

      config :minutemodem_mobile, MinutemodemMobile.Rig.HamlibStateMachine,
        model: 1,                    # Hamlib model number; default dummy (1)
        conf: %{}                    # config tokens applied before open

  `model` accepts an integer or one of the atoms `Hamlib.model/1` knows
  (`:dummy`, `:netrigctl`). On host with no rig attached the default dummy
  model round-trips values, so the whole CAT path is exercisable without
  hardware.

  ## Registration

  One process per rig, registered under `Minutewave.Rig.InstanceRegistry` with
  key `{rig_id, :hamlib}`, matching the existing per-rig instance pattern
  (`{rig_id, :control}`, `{rig_id, :modem_manager}`).
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  require Logger

  # Bounded backoff for reopen attempts after an error.
  @reopen_backoff_ms 500
  @reopen_backoff_max_ms 8_000

  defstruct [
    :rig_id,
    :model,
    :conf,
    # the owned Hamlib.Rig pid when open, else nil
    rig: nil,
    # last error term (for status/diagnostics)
    last_error: nil,
    reopen_backoff: @reopen_backoff_ms
  ]

  # ── Client API ─────────────────────────────────────────────────────────────

  def start_link(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    GenStateMachine.start_link(__MODULE__, opts, name: via(rig_id))
  end

  def via(rig_id) do
    {:via, Registry, {Minutewave.Rig.InstanceRegistry, {rig_id, :hamlib}}}
  end

  @doc "Open the CAT connection (start + open the Hamlib.Rig). Idempotent."
  @spec open(term()) :: :ok | {:error, term()}
  def open(rig_id), do: GenStateMachine.call(via(rig_id), :open)

  @doc "Close the CAT connection; the machine returns to `:closed`."
  @spec close(term()) :: :ok
  def close(rig_id), do: GenStateMachine.call(via(rig_id), :close)

  @doc """
  Replace the rig model and conf (from `RigConfig`). Stored for the next open
  when closed; when already open, CAT is closed and reopened with the new
  params so a model/baud/civaddr/ptt change takes effect immediately.
  """
  @spec reconfigure(term(), integer(), map()) :: :ok
  def reconfigure(rig_id, model, conf) when is_map(conf) do
    GenStateMachine.call(via(rig_id), {:reconfigure, model, conf})
  end

  @doc "Current frequency in Hz (integer). `{:error, :not_open}` when closed."
  @spec get_frequency(term()) :: {:ok, pos_integer()} | {:error, term()}
  def get_frequency(rig_id), do: GenStateMachine.call(via(rig_id), :get_frequency)

  @doc """
  Set frequency in Hz. Rejects non-integer / out-of-range values with
  `{:error, :bad_freq}` *before* they can reach the Hamlib C NIF (a bad
  `freq_t` into `rig_set_freq` is a native-fault surface).
  """
  @spec set_frequency(term(), pos_integer()) :: :ok | {:error, term()}
  def set_frequency(rig_id, hz) when is_integer(hz) and hz > 0 and hz < 1_000_000_000 do
    GenStateMachine.call(via(rig_id), {:set_frequency, hz})
  end

  def set_frequency(_rig_id, _hz), do: {:error, :bad_freq}

  @doc "Current mode as a `Minutewave.Rig.Control.Behaviour` mode atom."
  @spec get_mode(term()) :: {:ok, atom()} | {:error, term()}
  def get_mode(rig_id), do: GenStateMachine.call(via(rig_id), :get_mode)

  @doc "Set mode by `Control.Behaviour` mode atom (`:usb`, `:lsb`, `:digital`, …)."
  @spec set_mode(term(), atom()) :: :ok | {:error, term()}
  def set_mode(rig_id, mode) when is_atom(mode) do
    GenStateMachine.call(via(rig_id), {:set_mode, mode})
  end

  def set_mode(_rig_id, _mode), do: {:error, :bad_mode}

  @doc """
  Key (`true`) or unkey (`false`) PTT via Hamlib.

  With `ptt_type=RTS` configured (see `config.exs`), this keys the RTS line on
  the rig's serial port — which on the DigiRig is the CP2102 RTS = radio PTT.
  Routing PTT through Hamlib (rather than a second, independent RTS owner) keeps
  the CP2102 single-owner while preserving the low-latency RTS keying the
  half-duplex T/R gate needs. `{:error, :not_open}` when CAT is closed.
  """
  @spec set_ptt(term(), boolean()) :: :ok | {:error, term()}
  def set_ptt(rig_id, on) when is_boolean(on) do
    GenStateMachine.call(via(rig_id), {:set_ptt, on})
  end

  def set_ptt(_rig_id, _on), do: {:error, :bad_ptt}

  @doc """
  Machine status map: `%{state:, frequency:, mode:, last_error:}`.

  `frequency`/`mode` are `nil` when not open.
  """
  @spec status(term()) :: {:ok, map()}
  def status(rig_id), do: GenStateMachine.call(via(rig_id), :status)

  # ── Init ───────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    rig_id = Keyword.fetch!(opts, :rig_id)
    cfg = Application.get_env(:minutemodem_mobile, __MODULE__, [])

    model =
      opts[:model] || cfg[:model] || Hamlib.model(:dummy)

    conf = opts[:conf] || cfg[:conf] || %{}

    Logger.metadata(rig: String.slice(to_string(rig_id), 0, 8))

    # Trap exits so a linked Hamlib.Rig crash (missing/broken NIF, serial port
    # failure) arrives as an {:EXIT, pid, reason} message we handle, rather
    # than taking this state machine down with it.
    Process.flag(:trap_exit, true)

    data = %__MODULE__{
      rig_id: rig_id,
      model: normalize_model(model),
      conf: conf
    }

    Logger.info("[Rig.Hamlib] Started for #{inspect(rig_id)} (model=#{data.model}); closed")
    {:ok, :closed, data}
  end

  # ── State: :closed ─────────────────────────────────────────────────────────

  def closed(:enter, _old, _data), do: :keep_state_and_data

  def closed({:call, from}, :open, data) do
    {:next_state, :opening, data, [{:reply, from, :ok}, {:next_event, :internal, :do_open}]}
  end

  def closed({:call, from}, :close, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def closed({:call, from}, {:reconfigure, model, conf}, data) do
    {:keep_state, %{data | model: normalize_model(model), conf: conf}, [{:reply, from, :ok}]}
  end

  def closed({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, status_map(:closed, nil, nil, data)}}]}
  end

  # CAT calls while closed: report cleanly rather than crash.
  def closed({:call, from}, req, _data)
      when req in [:get_frequency, :get_mode] do
    {:keep_state_and_data, [{:reply, from, {:error, :not_open}}]}
  end

  def closed({:call, from}, {req, _arg}, _data)
      when req in [:set_frequency, :set_mode, :set_ptt] do
    {:keep_state_and_data, [{:reply, from, {:error, :not_open}}]}
  end

  # Trapped EXIT from a just-stopped rig, or any stray info — swallow.
  def closed(:info, {:EXIT, _pid, _reason}, _data), do: :keep_state_and_data
  def closed(:info, _other, _data), do: :keep_state_and_data

  # ── State: :opening ────────────────────────────────────────────────────────

  def opening(:enter, _old, _data), do: :keep_state_and_data

  def opening(:internal, :do_open, data) do
    cond do
      not hamlib_available?() ->
        # The hamlib NIF isn't loaded in this build (e.g. an Android build
        # where the Hamlib C library hasn't been cross-compiled yet). Fail
        # fast into :error with a clear cause rather than calling into a
        # missing NIF — which raises deep inside Hamlib.Rig.init and, because
        # start_link links, would otherwise propagate an exit to this machine.
        Logger.warning("[Rig.Hamlib] hamlib NIF unavailable — CAT cannot open")
        {:next_state, :error, %{data | rig: nil, last_error: :nif_unavailable}}

      true ->
        case start_rig(data) do
          {:ok, rig} ->
            Logger.info("[Rig.Hamlib] open (model=#{data.model})")

            {:next_state, :open,
             %{data | rig: rig, last_error: nil, reopen_backoff: @reopen_backoff_ms}}

          {:error, reason} ->
            Logger.warning("[Rig.Hamlib] open failed: #{inspect(reason)}")
            {:next_state, :error, %{data | rig: nil, last_error: reason}}
        end
    end
  end

  # Defer external calls until the open resolves (internal event runs first).
  def opening({:call, _from}, _req, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  # Trapped EXIT signals (trap_exit is on). Ignore here — the do_open result
  # is what transitions us; a stale EXIT must not crash the machine.
  def opening(:info, {:EXIT, _pid, _reason}, _data), do: :keep_state_and_data
  def opening(:info, _other, _data), do: :keep_state_and_data

  # ── State: :open ───────────────────────────────────────────────────────────

  def open(:enter, _old, _data), do: :keep_state_and_data

  def open({:call, from}, :open, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def open({:call, from}, :close, data) do
    _ = stop_rig(data.rig)
    {:next_state, :closed, %{data | rig: nil}, [{:reply, from, :ok}]}
  end

  # Reconfigure while open: drop the current rig and reopen with new params.
  def open({:call, from}, {:reconfigure, model, conf}, data) do
    _ = stop_rig(data.rig)
    data = %{data | rig: nil, model: normalize_model(model), conf: conf}
    {:next_state, :opening, data, [{:reply, from, :ok}, {:next_event, :internal, :do_open}]}
  end

  def open({:call, from}, :get_frequency, data) do
    reply =
      case Hamlib.Rig.get_freq(data.rig) do
        {:ok, hz} -> {:ok, round(hz)}
        err -> err
      end

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def open({:call, from}, {:set_frequency, hz}, data) do
    {:keep_state_and_data, [{:reply, from, Hamlib.Rig.set_freq(data.rig, hz)}]}
  end

  def open({:call, from}, :get_mode, data) do
    reply =
      case Hamlib.Rig.get_mode(data.rig) do
        {:ok, {mode_str, _passband}} -> {:ok, mode_from_hamlib(mode_str)}
        err -> err
      end

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def open({:call, from}, {:set_mode, mode}, data) do
    {:keep_state_and_data, [{:reply, from, Hamlib.Rig.set_mode(data.rig, mode_to_hamlib(mode), 0)}]}
  end

  def open({:call, from}, {:set_ptt, on}, data) do
    {:keep_state_and_data, [{:reply, from, Hamlib.Rig.set_ptt(data.rig, on)}]}
  end

  def open({:call, from}, :status, data) do
    freq =
      case Hamlib.Rig.get_freq(data.rig) do
        {:ok, hz} -> round(hz)
        _ -> nil
      end

    mode =
      case Hamlib.Rig.get_mode(data.rig) do
        {:ok, {mode_str, _}} -> mode_from_hamlib(mode_str)
        _ -> nil
      end

    {:keep_state_and_data, [{:reply, from, {:ok, status_map(:open, freq, mode, data)}}]}
  end

  # The owned Hamlib.Rig exited normally (deliberate stop) — stay consistent,
  # no error. This can arrive if a stop races a state change.
  def open(:info, {:EXIT, rig, reason}, %{rig: rig} = data)
      when reason in [:normal, :shutdown] do
    {:next_state, :closed, %{data | rig: nil}}
  end

  # The owned Hamlib.Rig died abnormally — drop to :error and schedule a reopen.
  def open(:info, {:EXIT, rig, reason}, %{rig: rig} = data) do
    Logger.warning("[Rig.Hamlib] rig process exited: #{inspect(reason)}")
    {:next_state, :error, %{data | rig: nil, last_error: reason}}
  end

  def open(:info, _other, _data), do: :keep_state_and_data

  # ── State: :error ──────────────────────────────────────────────────────────

  def error(:enter, _old, data) do
    backoff = min(data.reopen_backoff, @reopen_backoff_max_ms)
    {:keep_state, %{data | reopen_backoff: backoff * 2}, [{:state_timeout, backoff, :retry}]}
  end

  def error(:state_timeout, :retry, data) do
    {:next_state, :opening, data, [{:next_event, :internal, :do_open}]}
  end

  def error({:call, from}, :open, data) do
    # Caller explicitly asked: retry now rather than wait out the backoff.
    {:next_state, :opening, data, [{:reply, from, :ok}, {:next_event, :internal, :do_open}]}
  end

  def error({:call, from}, :close, data) do
    {:next_state, :closed, %{data | rig: nil}, [{:reply, from, :ok}]}
  end

  # Reconfigure from error: adopt new params and retry the open now.
  def error({:call, from}, {:reconfigure, model, conf}, data) do
    {:next_state, :opening, %{data | model: normalize_model(model), conf: conf},
     [{:reply, from, :ok}, {:next_event, :internal, :do_open}]}
  end

  def error({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, status_map(:error, nil, nil, data)}}]}
  end

  def error({:call, from}, req, _data)
      when req in [:get_frequency, :get_mode] do
    {:keep_state_and_data, [{:reply, from, {:error, :not_open}}]}
  end

  def error({:call, from}, {req, _arg}, _data)
      when req in [:set_frequency, :set_mode, :set_ptt] do
    {:keep_state_and_data, [{:reply, from, {:error, :not_open}}]}
  end

  # Trapped EXIT or stray info while waiting out backoff — swallow.
  def error(:info, {:EXIT, _pid, _reason}, _data), do: :keep_state_and_data
  def error(:info, _other, _data), do: :keep_state_and_data

  # ── Terminate ──────────────────────────────────────────────────────────────

  @impl true
  def terminate(_reason, _state, %{rig: rig}) do
    _ = stop_rig(rig)
    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp stop_rig(nil), do: :ok

  defp stop_rig(rig) do
    if Process.alive?(rig), do: GenServer.stop(rig, :normal, 2_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Start a Hamlib.Rig without letting a crash in its init (e.g. a broken NIF,
  # or a serial port that won't open) take down this state machine. trap_exit
  # is on (set in init/1), so a synchronous start crash surfaces as a caught
  # exit here and becomes {:error, reason}; we land cleanly in :error.
  defp start_rig(data) do
    case Hamlib.Rig.start_link(model: data.model, conf: data.conf, open: true) do
      {:ok, rig} -> {:ok, rig}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:rig_exit, reason}}
  end

  # Is the hamlib NIF actually loaded in this build? `Hamlib.version/0` calls
  # straight into the NIF; if the .so isn't loaded it raises (UndefinedFunction
  # once @on_load has failed, or ErlangError :nif_not_loaded). Either way,
  # absence => not available, and we never attempt a real open.
  defp hamlib_available? do
    is_binary(Hamlib.version())
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp normalize_model(model) when is_integer(model), do: model
  defp normalize_model(model) when is_atom(model), do: Hamlib.model(model)
  # A malformed configured model degrades to the dummy rig rather than raising.
  defp normalize_model(_), do: Hamlib.model(:dummy)

  defp status_map(state, freq, mode, data) do
    %{state: state, frequency: freq, mode: mode, last_error: data.last_error}
  end

  # ── Mode translation: Control.Behaviour atom ↔ Hamlib mode string ──────────
  # :digital maps to "USB" (the data sideband the modem couples through);
  # the operator's data never reaches the radio as a distinct PKT mode at
  # this stage — it's plain USB with the modem on the audio.

  defp mode_to_hamlib(:usb), do: "USB"
  defp mode_to_hamlib(:lsb), do: "LSB"
  defp mode_to_hamlib(:am), do: "AM"
  defp mode_to_hamlib(:fm), do: "FM"
  defp mode_to_hamlib(:cw), do: "CW"
  defp mode_to_hamlib(:digital), do: "USB"
  # Any unrecognized mode falls back to USB rather than raising a
  # FunctionClauseError that would crash-restart the CAT state machine.
  defp mode_to_hamlib(_), do: "USB"

  defp mode_from_hamlib("USB"), do: :usb
  defp mode_from_hamlib("LSB"), do: :lsb
  defp mode_from_hamlib("AM"), do: :am
  defp mode_from_hamlib("FM"), do: :fm
  defp mode_from_hamlib("CW"), do: :cw
  defp mode_from_hamlib("CWR"), do: :cw
  defp mode_from_hamlib("PKTUSB"), do: :digital
  defp mode_from_hamlib("PKTLSB"), do: :digital
  defp mode_from_hamlib(_other), do: :usb
end
