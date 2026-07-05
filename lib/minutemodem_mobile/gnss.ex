defmodule MinutemodemMobile.Gnss do
  @moduledoc """
  Android GNSS time source for the disciplined virtual clock.

  Bridges Android location fixes into `Minutewave.Clock`. The Kotlin side
  (`MobBridge`) runs a `LocationManager` GPS listener and, for each fix,
  delivers `{:mob_file_result, "gnss", "fix", json}` to this process, where
  `json` carries:

    * `utc_ms`   — the fix's UTC time (GPS-derived), ms since epoch.
    * `age_ms`   — how long ago the fix was captured, from Android's
      `elapsedRealtimeNanos` (monotonic), measured at delivery.
    * `unc_ms`   — uncertainty bound on the time.

  We reconstruct the fix's capture instant in the **BEAM's** monotonic timeline
  (`System.monotonic_time - age_ms`) — the two clocks tick at the same rate, so
  subtracting the age places the fix correctly — and hand it to
  `Minutewave.Clock.discipline_gnss/1` as a stratum-0 fix.

  ## Lifecycle

  On start we request the `:location` permission from *our own* pid (so the
  grant and the subsequent fixes are delivered here), after a short delay to let
  the Activity come up. GNSS is a **push** source per
  `Minutewave.Clock.Source` — no Poller; the platform calls us.
  """

  use GenServer
  require Logger

  alias Minutewave.Clock

  @request_delay_ms 3_000
  # Policy loop cadence and how fresh we keep the clock. The virtual clock holds
  # over for hours on one fix, so we only need a short GPS burst occasionally.
  @sync_check_ms 60_000
  @resync_interval_ms 15 * 60_000

  # -- API -------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Diagnostics snapshot: permission state, fix count, last fix time, provider."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Ask for the location permission again (e.g. after the operator enables it)."
  def request, do: GenServer.cast(__MODULE__, :request_location)

  # -- Server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Delay the permission request so the MainActivity is registered before we
    # ask (a request with no Activity is delivered as :denied).
    # Kick the policy loop after a short delay (lets the Activity come up).
    Process.send_after(self(), :sync_check, @request_delay_ms)

    {:ok,
     %{
       permission: :pending,
       fix_count: 0,
       last_fix_at: nil,
       last_fix_mono: nil,
       acquiring: false,
       provider: nil,
       # Tier-2 GnssStatus telemetry
       sats_visible: nil,
       sats_used: nil,
       max_cn0: nil,
       constellations: nil,
       ttff_ms: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:request_location, state) do
    request_location()
    {:noreply, state}
  end

  @impl true
  def handle_info(:request_location, state) do
    request_location()
    {:noreply, state}
  end

  # Policy loop: decide whether to fire a GPS acquisition burst, then reschedule.
  # This is the Elixir-driven duty cycle — GPS is off between bursts.
  def handle_info(:sync_check, state) do
    state =
      if should_acquire?(state) do
        Logger.info("[Gnss] acquisition burst — reason=#{acquire_reason(state)}")
        request_location()
        %{state | acquiring: true}
      else
        state
      end

    schedule_sync_check()
    {:noreply, state}
  end

  # Burst ended (Kotlin powered the chip down). Clear the acquiring flag so the
  # next stale/unsynced check can trigger another burst.
  def handle_info({:gnss, "burst", status}, state) do
    Logger.info("[Gnss] burst #{status}")
    {:noreply, %{state | acquiring: false}}
  end

  def handle_info({:permission, :location, :granted}, state) do
    Logger.info("[Gnss] location permission granted; awaiting GPS fixes")
    {:noreply, %{state | permission: :granted}}
  end

  def handle_info({:permission, :location, :denied}, state) do
    Logger.warning("[Gnss] location permission denied; GNSS clock source unavailable")
    {:noreply, %{state | permission: :denied}}
  end

  def handle_info({:mob_file_result, "gnss", "fix", json}, state) do
    case parse_fix(json) do
      {:ok, utc_ms, age_ms, unc_ms, provider} ->
        mono_ms = System.monotonic_time(:millisecond) - max(age_ms, 0)

        Clock.discipline_gnss(%{
          protocol_time_ms: utc_ms,
          mono_ms: mono_ms,
          uncertainty_ms: unc_ms,
          stratum: 0
        })

        {quality, unc} = safe_quality()

        Logger.info(
          "[Gnss] fix ##{state.fix_count + 1} #{provider} age=#{age_ms}ms -> clock #{quality} ±#{unc}ms"
        )

        {:noreply,
         %{
           state
           | fix_count: state.fix_count + 1,
             last_fix_at: DateTime.utc_now(),
             last_fix_mono: System.monotonic_time(:millisecond),
             acquiring: false,
             provider: provider
         }}

      :error ->
        Logger.debug("[Gnss] unparseable fix payload: #{inspect(json)}")
        {:noreply, state}
    end
  end

  def handle_info({:mob_file_result, "gnss", "status", json}, state) do
    case decode(json) do
      %{"visible" => v, "used" => u, "max_cn0" => c} = m ->
        {:noreply,
         %{
           state
           | sats_visible: to_int(v),
             sats_used: to_int(u),
             max_cn0: to_int(c),
             constellations: Map.get(m, "constellations")
         }}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:mob_file_result, "gnss", "ttff", json}, state) do
    case decode(json) do
      %{"ttff_ms" => t} -> {:noreply, %{state | ttff_ms: to_int(t)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:gnss, "provider", status}, state) do
    Logger.info("[Gnss] GPS provider #{status}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- helpers ---------------------------------------------------------------

  defp schedule_sync_check, do: Process.send_after(self(), :sync_check, @sync_check_ms)

  # Acquire when: permission isn't denied, no burst already running, and either
  # the clock is unsynced, we've never fixed, or the last fix is older than the
  # resync interval.
  defp should_acquire?(%{permission: :denied}), do: false
  defp should_acquire?(%{acquiring: true}), do: false

  defp should_acquire?(state) do
    {quality, _} = safe_quality()
    quality == :unsynced or fix_stale?(state)
  end

  defp acquire_reason(%{last_fix_mono: nil}), do: "cold"
  defp acquire_reason(state), do: if(fix_stale?(state), do: "resync", else: "quality")

  defp fix_stale?(%{last_fix_mono: nil}), do: true

  defp fix_stale?(%{last_fix_mono: t}) do
    System.monotonic_time(:millisecond) - t >= @resync_interval_ms
  end

  defp request_location do
    Logger.info("[Gnss] requesting location permission")
    Mob.Permissions.request(%Mob.Socket{}, :location)
    :ok
  rescue
    e -> Logger.warning("[Gnss] permission request failed: #{inspect(e)}")
  catch
    _, _ -> :ok
  end

  defp safe_quality do
    Clock.quality()
  catch
    :exit, _ -> {:unavailable, 0}
  end

  defp parse_fix(json) when is_binary(json) do
    case :json.decode(json) do
      %{"utc_ms" => utc, "age_ms" => age, "unc_ms" => unc} = m ->
        {:ok, to_int(utc), to_int(age), to_int(unc), Map.get(m, "provider", "gps")}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_fix(_), do: :error

  defp decode(json) when is_binary(json) do
    :json.decode(json)
  rescue
    _ -> :error
  end

  defp decode(_), do: :error

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)
  defp to_int(_), do: 0
end
