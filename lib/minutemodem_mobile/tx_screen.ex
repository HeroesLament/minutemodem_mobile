defmodule MinutemodemMobile.TxScreen do
  @moduledoc """
  Text → 110D audio.

  Type a message, tap Transmit. The text gets encoded as a MIL-STD-188-110D
  Appendix D waveform 4 (BPSK, 600 bps, short interleaver) and played out
  the device speaker.

  Boots the Minutewave modem stack on first mount (with a StubControl rig
  backend, since this screen doesn't talk to a real radio — it just renders
  to audio).
  """
  use Mob.Screen
  require Logger

  alias Minutewave.Modem

  @rig :tx_screen
  @sample_rate 9600
  @waveform 4
  @bw_khz 3
  @interleaver :short

  # -- Lifecycle ------------------------------------------------------------

  def mount(_params, _session, socket) do
    ensure_modem_started!()
    Modem.Events.subscribe(@rig, self())

    {:ok,
     Mob.Socket.assign(socket,
       text: Mob.State.get(:tx_draft, "hello world"),
       status: "idle",
       tx_buffer: [],
       capturing: false
     )}
  end

  # -- UI -------------------------------------------------------------------

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="MinuteModem — Text → 110D" text_size={:lg} text_color={:on_surface} padding={:space_sm} />
        <Text text="Waveform 4, BPSK, 600 bps" text_size={:sm} text_color={:muted} padding={4} />
        <Spacer size={16} />

        <Text text={"Status: #{assigns.status}"} text_size={:sm} text_color={:primary} padding={4} />
        <Spacer size={16} />

        <TextField
          value={assigns.text}
          placeholder="Type a message…"
          keyboard={:default}
          return_key={:done}
          on_change={{self(), :text_changed}}
        />
        <Spacer size={16} />

        <Button
          text="Transmit"
          background={:primary}
          text_color={:on_primary}
          padding={:space_md}
          fill_width={true}
          on_tap={{self(), :transmit}}
        />
      </Column>
    </Scroll>
    """
  end

  # -- Events ---------------------------------------------------------------

  def handle_info({:change, :text_changed, value}, socket) do
    Mob.State.put(:tx_draft, value)
    {:noreply, Mob.Socket.assign(socket, text: value)}
  end

  def handle_info({:tap, :transmit}, socket) do
    payload = socket.assigns.text

    cond do
      payload == "" ->
        {:noreply, Mob.Socket.assign(socket, status: "empty input")}

      socket.assigns.capturing ->
        {:noreply, Mob.Socket.assign(socket, status: "already transmitting")}

      true ->
        socket =
          Mob.Socket.assign(socket,
            tx_buffer: [],
            capturing: true,
            status: "encoding…"
          )

        srv = Modem.TxFSM.via(@rig)
        Modem.TxFSM.arm(srv)
        Modem.TxFSM.data(srv, payload, :last)
        Modem.TxFSM.start(srv)

        {:noreply, socket}
    end
  end

  # Capture TX samples as they're produced
  def handle_info({:modem, {:tx_audio, samples}}, %{assigns: %{capturing: true}} = socket) do
    new_buf = socket.assigns.tx_buffer ++ samples
    {:noreply, Mob.Socket.assign(socket, tx_buffer: new_buf)}
  end

  # When the FSM is draining the last block, write WAV and play
  def handle_info({:modem, {:tx_status, %{state: :draining_ok}}}, %{assigns: %{capturing: true}} = socket) do
    samples = socket.assigns.tx_buffer
    n = length(samples)

    path = Path.join(Mob.Storage.dir(:cache), "minutemodem_tx.wav")
    write_wav!(path, samples, @sample_rate)
    Logger.info("[TxScreen] wrote #{n} samples to #{path}")

    socket = Mob.Audio.play(socket, path)

    {:noreply,
     Mob.Socket.assign(socket,
       capturing: false,
       status: "playing #{n} samples (#{Float.round(n / @sample_rate, 2)}s)"
     )}
  end

  # Don't care about other events
  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Helpers --------------------------------------------------------------

  defp ensure_modem_started! do
    case Registry.lookup(Minutewave.Modem.Registry, {@rig, :supervisor}) do
      [{_pid, _}] ->
        :ok

      [] ->
        {:ok, _} = MinutemodemMobile.Rig.StubControl.start_link(rig_id: @rig)

        {:ok, _} =
          Minutewave.Modem.Supervisor.start_link(
            rig_id: @rig,
            waveform: @waveform,
            bw_khz: @bw_khz,
            interleaver: @interleaver,
            constraint_length: 7,
            sample_rate: @sample_rate
          )
    end
  end

  defp write_wav!(path, samples, sample_rate) do
    pcm = for s <- samples, into: <<>>, do: <<clip16(s)::little-signed-16>>
    data_size = byte_size(pcm)
    chunk_size = data_size + 36
    byte_rate = sample_rate * 2

    header =
      "RIFF" <>
        <<chunk_size::little-32>> <>
        "WAVE" <>
        "fmt " <>
        <<16::little-32, 1::little-16, 1::little-16,
          sample_rate::little-32, byte_rate::little-32,
          2::little-16, 16::little-16>> <>
        "data" <>
        <<data_size::little-32>>

    {:ok, _} = Mob.Storage.write(path, header <> pcm)
    :ok
  end

  defp clip16(s) when s > 32767, do: 32767
  defp clip16(s) when s < -32768, do: -32768
  defp clip16(s), do: s
end
