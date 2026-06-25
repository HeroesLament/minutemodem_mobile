defmodule MinutemodemMobile.App do
  @moduledoc "Application entry point for MinutemodemMobile."

  use Mob.App

  @impl Mob.App
  # Android renders a native left drawer; iOS native drawer support is
  # deferred in Mob 0.7.5, so it falls back to a plain stack there.
  # Single stack rooted at ShellScreen, which renders its own bottom TabBar
  # node (CONFIG / NETWORK). Mob 0.7.5's framework tab_bar/drawer nav is not
  # wired through the render path, so we drive the tab bar from the screen.
  def navigation(_platform) do
    stack(:main, root: MinutemodemMobile.ShellScreen)
  end

  @impl Mob.App
  def on_start do
    # Minutewave app env — normally loaded from config/config.exs, but Mob's
    # start_clean boot doesn't load consumer config. Apply ours explicitly.
    Application.put_env(:minutewave, :phy_modem_nif, MinutemodemMobile.Nifs.PhyModem)
    Application.put_env(:minutewave, :audio_backend, MinutemodemMobile.Audio.LoopbackBackend)
    Application.put_env(:minutewave, :rig_control,   MinutemodemMobile.Rig.StubControl)

    # Minutewave registries — normally started by Minutewave.Application,
    # but Mob's start_clean boot doesn't start path-dep applications.
    # Start them here before any screen tries to use them.
    {:ok, _} = Registry.start_link(keys: :unique, name: Minutewave.Modem.Registry)
    {:ok, _} = Registry.start_link(keys: :unique, name: Minutewave.Rig.InstanceRegistry)
    {:ok, _} = Registry.start_link(keys: :unique, name: Minutewave.Interface.Registry)

    # Audio backend — receives :subscribe calls from RxFSM at startup.
    # Same reason: MinutemodemMobile.Application doesn't run under Mob,
    # so we start the GenServer here.
    {:ok, _} = MinutemodemMobile.Audio.LoopbackBackend.start_link([])

    # Configure BEAM's DNS path so Req / Finch / Mint / `gen_tcp:connect/3`
    # with a hostname work on iOS without per-host setup. Flips the lookup
    # chain from the iOS-broken `:native` (inet_gethost port program) path
    # to `[:file, :dns]` and seeds Google + Cloudflare as fallback
    # nameservers. Override with `nameservers:` if you need to (corporate
    # resolver, Quad9, etc.) — see `Mob.DNS.configure_pure_beam/1`.
    #
    # For hosts that need Apple's resolver (VPN-pushed DNS, mDNS,
    # captive portals, search-domain expansion) call `Mob.DNS.resolve/1`
    # for those specific hostnames here too. Both paths compose.
    Mob.DNS.configure_pure_beam()

    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = MinutemodemMobile.Repo.start_link()
    Ecto.Migrator.with_repo(MinutemodemMobile.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_dir(), :up, all: true)
    end)

    Mob.Screen.start_root(MinutemodemMobile.ShellScreen)
    Mob.Dist.ensure_started(node: :"minutemodem_mobile_android@127.0.0.1", cookie: :mob_secret)
  end

  # Returns the path to the migrations directory for the current environment.
  #
  # WHY NOT Application.app_dir/2?
  #
  # Application.app_dir(app, "priv/repo/migrations") calls :code.priv_dir(app)
  # under the hood. That works in a normal `mix run` dev environment where the
  # app lives in $OTP_ROOT/lib/APP-VERSION/ebin/.
  #
  # On Android and iOS, Mob deploys .beam files to a flat -pa directory with no
  # versioned lib structure, so :code.priv_dir/1 returns {error, bad_name}.
  # Ecto.Migrator.run/3 silently finds zero migrations and logs "Migrations
  # already up" — tables are never created and any query against them crashes
  # the screen GenServer, making the screen appear frozen.
  #
  # The fix: mob_beam.c/mob_beam.m set MOB_BEAMS_DIR=beams_dir before erl_start.
  # The deployer pushes priv/ into beams_dir/priv/ and runs chmod -R 755 on it
  # (mkdir-as-root creates system:system drwxrwx--x dirs that the app process
  # can traverse but not list, breaking Path.wildcard). Here we read MOB_BEAMS_DIR
  # and pass the explicit path to Ecto.Migrator.run/4.
  defp migrations_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil       -> Application.app_dir(:minutemodem_mobile, "priv/repo/migrations")
      beams_dir -> Path.join([beams_dir, "priv", "repo", "migrations"])
    end
  end
end
