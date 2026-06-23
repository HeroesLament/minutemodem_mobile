defmodule MinutemodemMobile.HomeScreen do
  @moduledoc "Landing screen for MinutemodemMobile."
  use Mob.Screen

  def mount(_params, _session, socket) do
    Mob.Theme.set(Mob.Theme.Adaptive)
    {:ok, socket}
  end

  def render(assigns) do
    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Image src={logo_src()} width={120} height={120} content_mode="fit" />
        <Spacer size={16} />
        <Text text="MinutemodemMobile" text_size={:xl} text_color={:on_surface} padding={:space_sm} />
        <Text text="BEAM running on device" text_size={:sm} text_color={:primary} padding={4} />
        <Spacer size={40} />
        {nav_button("MinuteModem (Text → 110D)", :open_tx)}
        <Spacer size={12} />
        {nav_button("Text Input", :open_text)}
        <Spacer size={12} />
        {nav_button("Audio", :open_audio)}
        <Spacer size={12} />
        {nav_button("Storage", :open_storage)}
      </Column>
    </Scroll>
    """
  end

  def handle_info({:tap, :open_tx}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, MinutemodemMobile.TxScreen)}
  end

  def handle_info({:tap, :open_text}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, MinutemodemMobile.TextScreen)}
  end

  def handle_info({:tap, :open_audio}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, MinutemodemMobile.AudioScreen)}
  end

  def handle_info({:tap, :open_storage}, socket) do
    {:noreply, Mob.Socket.push_screen(socket, MinutemodemMobile.StorageScreen)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp nav_button(label, tag) do
    tap = {self(), tag}
    ~MOB(<Button text={label} background={:primary} text_color={:on_primary} text_size={:lg} padding={:space_md} fill_width={true} on_tap={tap} />)
  end

  defp logo_src, do: Path.join(rootdir(), "mob_logo_light.png")

  # ROOTDIR is set by mob_beam (iOS) and mob_beam.c (Android) before erl_start,
  # so this fallback is only exercised in unit tests on the host. Don't put
  # `Path.expand("~/...")` directly in `System.get_env/2`'s default argument —
  # default args evaluate eagerly, and Android's BEAM has no `HOME` env var,
  # so `System.user_home!()` would raise `RuntimeError` and abort the screen
  # before the first render.
  defp rootdir do
    case System.get_env("ROOTDIR") do
      nil -> Path.expand("~/.mob/runtime/ios-sim")
      val -> val
    end
  end
end
