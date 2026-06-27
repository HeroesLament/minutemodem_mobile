defmodule MinutemodemMobile.AudioPcm do
  @moduledoc """
  Real-time PCM duplex audio for DSP use (softmodem + operator voice).
  **Android only.**

  This is the BEAM-side wrapper over Mob's `audio_pcm_*` native bridge
  (`MobBridge.kt` + `mob_nif.zig` + `beam_jni.c`). It moves raw PCM only;
  all framing, resampling, modulation/demodulation, and vocoding live in
  Elixir/Rust above this layer.

  ## Design boundary: the bridge classifies, Elixir decides

  The native layer faithfully classifies every hardware fact into a typed
  event and never decides policy. Recovery, half-duplex T/R gating, and TX
  inhibition all live in an app-side supervising GenServer that owns the
  sessions. In particular: a `:stream_silent` event is just a *fact* (the
  capture stream went quiet); whether that is a fault or expected (PTT keyed
  during a half-duplex transmit) is the GenServer's call, because only it
  knows the T/R state.

  ## Why this exists

  Mob's stock audio backend (`Mob.Audio` / `audio_play`) is
  `MediaRecorder`/`MediaPlayer` — lossy AAC files to/from the default
  device. Unusable for a softmodem, which needs live, bit-exact PCM with
  explicit device targeting. This wrapper drives an `AudioRecord` +
  `AudioTrack` pair per stream, each pinned to a chosen device via
  `setPreferredDevice`, capture using `AudioSource.UNPROCESSED` to bypass
  the OS voice DSP (AGC/NS/AEC) that would mangle modem tones.

  ## The two-domain, always-on design

  The blessed hardware path is a DigiRig (CM108 codec over OTG USB) as the
  modem, and a Shokz LE Audio headset as the operator voice path. Both
  domains run concurrently as independent pinned streams — there is no
  global communication-route lock (`setCommunicationDevice`), precisely so
  the two can coexist. `UNPROCESSED` is load-bearing here: it is *not*
  privacy-sensitive, so two `UNPROCESSED` streams stay in the
  concurrently-capturable class (a `VOICE_COMMUNICATION` stream would be
  private by default and could silence the other). Open this twice: once
  pinned to the USB device, once to the BLE headset. The bridge is
  domain-agnostic; the session id disambiguates, and Elixir owns the
  modem-vs-voice mapping.

  ## Concurrent dual capture is HAL-dependent, and silencing is invisible

  Android does not guarantee concurrent capture from two real input
  devices — it is delegated to the device audio HAL, and the concurrency
  policy *silences* (delivers zeros) rather than erroring. Two independent
  detectors surface this:

    * `open/2` reports the actually-routed device ids in `:opened`
      (`record_routed_id` / `play_routed_id`); compare them to the ids you
      pinned to detect a HAL that silently re-routed or refused a stream.
    * an `AudioRecordingCallback` surfaces framework silencing/re-routing
      as `:route_changed` (carries `silenced` + `active_device_id`).
    * a running-RMS zero-detector in the read loop emits edge-triggered
      `:stream_silent` / `:stream_active` (covers the case where the
      callback does not fire because the app "isn't receiving audio").

  ## Lifecycle and events

  ```
  list_devices/1  → {:audio_pcm, :devices, [device, …]}
  open/2          → {:audio_pcm, :opened, %{…}}    (requested vs actual)
                    {:audio_pcm, :error, reason}
  write/3         → (no reply; enqueues PCM; drops-and-counts on overflow)
  close/2         → (no reply)
  ```

  Captured PCM arrives continuously after `open/2` as
  `{:audio_pcm, :data, session, binary}` — signed 16-bit little-endian
  interleaved frames.

  Asynchronous facts (all session-scoped):

    * `{:audio_pcm, :route_changed, %{session:, silenced:, active_device_id:}}`
    * `{:audio_pcm, :stream_silent, session}` / `{:audio_pcm, :stream_active, session}`
    * `{:audio_pcm, :write_overflow, session, dropped_total}`
    * `{:audio_pcm, :error, reason, session}` where `reason` is an atom:
      `:dead` (stream gone, recreate), `:invalid_state`, `:bad_value`,
      `:read_error`, `:write_error`, `:read_exception`, `:write_exception`,
      `:no_session`, plus open-time `:record_init_failed`,
      `:track_init_failed`, `:bad_record_format`, `:bad_play_format`,
      `:no_audio_manager`, `:open_failed`.

  ## Device shape

  Devices arrive as maps:

      %{
        id:           14,        # stable within a connection; pass to open/2
        type:         11,        # AudioDeviceInfo.TYPE_* (11=USB, 26=BLE)
        product_name: "DigiRig",
        address:      "...",     # USB/BLE address; disambiguates same-type
        is_source:    true,      # has a capture role
        is_sink:      false,     # has a playback role
        is_usb:       true,
        is_le:        false
      }
  """

  @type device :: %{
          id: integer(),
          type: integer(),
          product_name: String.t(),
          address: String.t(),
          is_source: boolean(),
          is_sink: boolean(),
          is_usb: boolean(),
          is_le: boolean()
        }

  @type session :: integer()
  @type processing :: :raw | :voice

  # AudioDeviceInfo.TYPE_* constants worth naming on the BEAM side.
  @type_usb_device 11
  @type_ble_headset 26

  @doc "AudioDeviceInfo.TYPE_USB_DEVICE — the DigiRig modem codec."
  def type_usb_device, do: @type_usb_device

  @doc "AudioDeviceInfo.TYPE_BLE_HEADSET — the Shokz operator headset."
  def type_ble_headset, do: @type_ble_headset

  @doc """
  Enumerate input + output audio devices.

  Result: `{:audio_pcm, :devices, [device, …]}`. Filter the list by
  `:type`/`:is_usb`/`:is_le` to find the DigiRig and the Shokz.
  """
  @spec list_devices(Mob.Socket.t()) :: Mob.Socket.t()
  def list_devices(socket) do
    :mob_nif.audio_pcm_list_devices()
    socket
  end

  @doc """
  Open a pinned full-duplex PCM stream.

  Options:
    * `:sample_rate` — Hz (default `48000`)
    * `:channels` — `1` or `2` (default `1`)
    * `:record_device_id` — pin capture to this `AudioDeviceInfo.id`
    * `:play_device_id` — pin playback to this `AudioDeviceInfo.id`
    * `:processing` — `:raw` (default) requests `AudioSource.UNPROCESSED`
      (no AGC/NS/AEC, non-privacy-sensitive); `:voice` requests
      `VOICE_RECOGNITION`. The `:opened` reply reports what was actually
      granted.
    * `:chunk_frames` — capture delivery granularity in frames (default `1024`)
    * `:silence_epsilon` — RMS (0.0–1.0 full-scale) below which a chunk is
      "low"; sustained low triggers `:stream_silent` (default `0.01`, ≈1%)
    * `:silence_window_ms` — how long sustained-low before `:stream_silent`
      (default `500`)
    * `:write_queue_chunks` — bounded writer-queue depth; overflow
      drops-and-counts (default `32`)

  Result:
    * `{:audio_pcm, :opened, %{session:, source:, processing:,
       requested_record_id:, requested_play_id:, record_routed_id:,
       play_routed_id:, sample_rate:, channels:}}`
    * `{:audio_pcm, :error, reason}`

  After `:opened`, captured PCM streams as
  `{:audio_pcm, :data, session, binary}`.
  """
  @spec open(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def open(socket, opts \\ []) do
    fields =
      %{
        "sample_rate" => Keyword.get(opts, :sample_rate, 48_000),
        "channels" => Keyword.get(opts, :channels, 1),
        "processing" => processing_string(Keyword.get(opts, :processing, :raw)),
        "chunk_frames" => Keyword.get(opts, :chunk_frames, 1024),
        "silence_epsilon" => Keyword.get(opts, :silence_epsilon, 0.01),
        "silence_window_ms" => Keyword.get(opts, :silence_window_ms, 500),
        "write_queue_chunks" => Keyword.get(opts, :write_queue_chunks, 32)
      }
      |> maybe_put("record_device_id", Keyword.get(opts, :record_device_id))
      |> maybe_put("play_device_id", Keyword.get(opts, :play_device_id))

    json = :json.encode(fields)
    :mob_nif.audio_pcm_open(json)
    socket
  end

  defp processing_string(:voice), do: "voice"
  defp processing_string(_), do: "raw"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  @doc """
  Enqueue PCM bytes (s16le interleaved) to a session's AudioTrack for
  playback / TX. The bytes are flattened and copied native-side before the
  NIF returns. No reply.

  Backpressure is non-blocking: if the bounded writer queue is full the
  bridge drops the oldest queued chunk and emits
  `{:audio_pcm, :write_overflow, session, dropped_total}`.
  """
  @spec write(Mob.Socket.t(), session(), iodata()) :: Mob.Socket.t()
  def write(socket, session, data) when is_integer(session) do
    bin = IO.iodata_to_binary(data)

    if byte_size(bin) > 0 do
      :mob_nif.audio_pcm_write(session, bin)
    end

    socket
  end

  @doc "Stop and release a session's record + track streams. Idempotent."
  @spec close(Mob.Socket.t(), session()) :: Mob.Socket.t()
  def close(socket, session) when is_integer(session) do
    :mob_nif.audio_pcm_close(session)
    socket
  end

  # ── Event normalization ────────────────────────────────────────────────
  #
  # `list_devices`/`open` and the `route_changed` monitor deliver their
  # payloads as JSON binaries via the shared file-result path, arriving as
  # `{:mob_file_result, "audio_pcm", sub, json}`. The atom-style facts
  # (silent/active/overflow/error) arrive via the atom3 path as
  # `{:audio_pcm, "<verb>", "<arg>"}` with string members. Call
  # `normalize_message/1` before the screen/GenServer's `handle_info/2`
  # (same precedent as `Mob.VendorUsb.normalize_message/1`) so user code
  # only sees clean `{:audio_pcm, …}` shapes. `:data` passes through.

  @doc false
  @spec normalize_message(term()) :: term()
  def normalize_message({:mob_file_result, "audio_pcm", "devices", json})
      when is_binary(json) do
    devices = json |> :json.decode() |> Enum.map(&device_from_map/1)
    {:audio_pcm, :devices, devices}
  end

  def normalize_message({:mob_file_result, "audio_pcm", "opened", json})
      when is_binary(json) do
    {:audio_pcm, :opened, opened_from_map(:json.decode(json))}
  end

  def normalize_message({:mob_file_result, "audio_pcm", "route_changed", json})
      when is_binary(json) do
    {:audio_pcm, :route_changed, route_changed_from_map(:json.decode(json))}
  end

  # Atom-path facts: the third member is a stringified integer.
  def normalize_message({:audio_pcm, "stream_silent", sid}) when is_binary(sid),
    do: {:audio_pcm, :stream_silent, to_int(sid)}

  def normalize_message({:audio_pcm, "stream_active", sid}) when is_binary(sid),
    do: {:audio_pcm, :stream_active, to_int(sid)}

  def normalize_message({:audio_pcm, "write_overflow", total}) when is_binary(total),
    do: {:audio_pcm, :write_overflow, to_int(total)}

  # Atom-path error: {:audio_pcm, "error", "<reason>"} → {:audio_pcm, :error, atom}
  def normalize_message({:audio_pcm, "error", reason}) when is_binary(reason),
    do: {:audio_pcm, :error, error_reason(reason)}

  def normalize_message(other), do: other

  defp device_from_map(map) when is_map(map) do
    %{
      id: Map.get(map, "id"),
      type: Map.get(map, "type"),
      product_name: Map.get(map, "product_name"),
      address: Map.get(map, "address"),
      is_source: Map.get(map, "is_source"),
      is_sink: Map.get(map, "is_sink"),
      is_usb: Map.get(map, "is_usb"),
      is_le: Map.get(map, "is_le")
    }
  end

  defp opened_from_map(map) when is_map(map) do
    %{
      session: Map.get(map, "session"),
      source: Map.get(map, "source"),
      processing: Map.get(map, "processing"),
      requested_record_id: Map.get(map, "requested_record_id"),
      requested_play_id: Map.get(map, "requested_play_id"),
      record_routed_id: Map.get(map, "record_routed_id"),
      play_routed_id: Map.get(map, "play_routed_id"),
      sample_rate: Map.get(map, "sample_rate"),
      channels: Map.get(map, "channels")
    }
  end

  defp route_changed_from_map(map) when is_map(map) do
    %{
      session: Map.get(map, "session"),
      silenced: Map.get(map, "silenced"),
      active_device_id: Map.get(map, "active_device_id")
    }
  end

  # Map the known native error strings to atoms; unknowns pass through as
  # a {:unknown, string} pair so nothing is silently lost.
  @known_errors ~w(dead invalid_state bad_value read_error write_error
                   read_exception write_exception no_session no_context
                   no_audio_manager record_init_failed track_init_failed
                   bad_record_format bad_play_format open_failed list_failed)
  defp error_reason(s) when s in @known_errors, do: String.to_atom(s)
  defp error_reason(s), do: {:unknown, s}

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> s
    end
  end
end
