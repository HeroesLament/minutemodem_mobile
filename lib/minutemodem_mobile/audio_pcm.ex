defmodule MinutemodemMobile.AudioPcm do
  @moduledoc """
  Real-time PCM duplex audio for DSP use (softmodem + operator voice).
  **Android only.**

  This is the BEAM-side wrapper over Mob's `audio_pcm_*` native bridge
  (`MobBridge.kt` + `mob_nif.zig` + `beam_jni.c`). It moves raw PCM only;
  all framing, resampling, modulation/demodulation, and vocoding live in
  Elixir/Rust above this layer.

  ## Why this exists

  Mob's stock audio backend (`audio_start_recording` / `audio_play`) is
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
  the two can coexist. Open this twice: once pinned to the USB device
  (`type` 11), once pinned to the BLE headset (`type` 26). The framework
  bridge is domain-agnostic; the session id disambiguates the streams and
  Elixir owns the modem-vs-voice mapping.

  ## Concurrent dual capture is HAL-dependent

  Android does not guarantee concurrent capture from two real input
  devices — it is delegated to the device audio HAL. `open/2` reports the
  actually-routed device ids in its `:opened` event
  (`record_routed_id` / `play_routed_id`); compare them to the ids you
  pinned to detect a HAL that silently re-routed or refused a stream.

  ## Lifecycle

  ```
  list_devices/1  → {:audio_pcm, :devices, [device, …]}
  open/2          → {:audio_pcm, :opened, %{session:, source:,
                                            record_routed_id:, play_routed_id:}}
                    {:audio_pcm, :error, reason}
  write/3         → (no reply; enqueues PCM to the session's AudioTrack)
  close/2         → (no reply)
  ```

  Captured PCM arrives continuously after `open/2` as
  `{:audio_pcm, :data, session, binary}` — signed 16-bit little-endian
  interleaved frames.

  ## Device shape

  Devices arrive as maps:

      %{
        id:           14,        # stable within a connection; pass to open/2
        type:         11,        # AudioDeviceInfo.TYPE_* (11=USB, 26=BLE)
        product_name: "DigiRig",
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
          is_source: boolean(),
          is_sink: boolean(),
          is_usb: boolean(),
          is_le: boolean()
        }

  @type session :: integer()

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
    * `:unprocessed` — request `AudioSource.UNPROCESSED` (default `true`);
      falls back to `VOICE_RECOGNITION` then `DEFAULT` when the platform
      or route declines it
    * `:chunk_frames` — capture delivery granularity in frames
      (default `1024`)

  Result:
    * `{:audio_pcm, :opened, %{session:, source:, record_routed_id:,
       play_routed_id:}}`
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
        "unprocessed" => Keyword.get(opts, :unprocessed, true),
        "chunk_frames" => Keyword.get(opts, :chunk_frames, 1024)
      }
      |> maybe_put("record_device_id", Keyword.get(opts, :record_device_id))
      |> maybe_put("play_device_id", Keyword.get(opts, :play_device_id))

    json = :json.encode(fields)
    :mob_nif.audio_pcm_open(json)
    socket
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  @doc """
  Enqueue PCM bytes (s16le interleaved) to a session's AudioTrack for
  playback / TX. The bytes are flattened and copied native-side before the
  NIF returns. No reply.
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
  # `list_devices` and `open` deliver their payloads as JSON binaries via
  # the shared file-result path, arriving as
  # `{:mob_file_result, "audio_pcm", sub, json}`. Call `normalize_message/1`
  # before the screen's `handle_info/2` (same precedent as
  # `Mob.VendorUsb.normalize_message/1`) so user code only sees the public
  # `{:audio_pcm, …}` shapes. The `:data` and `:error` events arrive in
  # final form already and pass through untouched.

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

  def normalize_message(other), do: other

  defp device_from_map(map) when is_map(map) do
    %{
      id: Map.get(map, "id"),
      type: Map.get(map, "type"),
      product_name: Map.get(map, "product_name"),
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
      record_routed_id: Map.get(map, "record_routed_id"),
      play_routed_id: Map.get(map, "play_routed_id")
    }
  end
end
