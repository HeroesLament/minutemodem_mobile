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
    # KEEP IN SYNC WITH config/config.exs (which the device never reads).
    Application.put_env(:minutewave, :phy_modem_nif, MinutemodemMobile.Nifs.PhyModem)
    Application.put_env(:minutewave, :audio_backend, MinutemodemMobile.Audio.UsbPcmBackend)
    Application.put_env(:minutewave, :rig_control,   MinutemodemMobile.Rig.HamlibControl)
    Application.put_env(:minutewave, :lqa_store,     MinutemodemMobile.ALE.LqaStore)

    # Hamlib CAT state machine: IC-706MkII (model 3010, default CI-V addr 0x4E)
    # over the android-usb serial bridge, PTT on the CP2102 RTS line
    # (ptt_type=RTS). Read at runtime by HamlibStateMachine.init/1. The radio's
    # CI-V baud must match serial_speed (the 706MkII has no CI-V auto-baud).
    Application.put_env(:minutemodem_mobile, MinutemodemMobile.Rig.HamlibStateMachine,
      model: 3010,
      conf: %{
        "rig_pathname" => "android-usb:0:0",
        "serial_speed" => "19200",
        "ptt_type" => "RTS"
      }
    )

    # Minutewave registries — normally started by Minutewave.Application,
    # but Mob's start_clean boot doesn't start path-dep applications.
    # Start them here before any screen tries to use them.
    {:ok, _} = Registry.start_link(keys: :unique, name: Minutewave.Modem.Registry)
    {:ok, _} = Registry.start_link(keys: :unique, name: Minutewave.Rig.InstanceRegistry)
    {:ok, _} = Registry.start_link(keys: :unique, name: Minutewave.Interface.Registry)

    # RigState — the ETS-backed outward projection each ALE Link publishes its
    # viewable state to. The table is created in RigState.init/1, so this owner
    # MUST be up before any Link starts, or Link.publish_state/2 crashes on a
    # missing ETS table (which, via the screen's blocking :infinity call to the
    # Link, took the whole UI down). Normally started by Minutewave.Application,
    # which Mob's clean boot skips.
    case Minutewave.RigState.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Disciplined virtual clock — the GNSS/TOD time source for synchronous ALE
    # scan. Normally started by Minutewave.Application, which Mob's clean boot
    # skips, so start it here before anything reads protocol time.
    case Minutewave.Clock.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # GNSS time source: feeds Minutewave.Clock from Android location fixes.
    {:ok, _} = MinutemodemMobile.Gnss.start_link([])

    # Repo + migrations must come up *before* the rig/modem supervision tree so
    # the persisted CAT config (RigConfig) can override the hardcoded Hamlib
    # defaults before HamlibStateMachine starts and reads its env.
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = MinutemodemMobile.Repo.start_link()

    Ecto.Migrator.with_repo(MinutemodemMobile.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_dir(), :up, all: true)
    end)

    apply_rig_config()

    # Modem session supervisor — starts the Manager (mechanism: owns the
    # AudioPcm + CP2102 hardware sessions + the half-duplex T/R gate) and the
    # minutewave Modem subsystem (protocol: TxFSM/RxFSM/Arbiter). RxFSM
    # subscribes to the USB audio backend at startup, which routes to the
    # Manager and is safe with no hardware session open (it just records the
    # subscriber). The physical session is started deliberately later via
    # MinutemodemMobile.Modem.Manager.start_session/2 — we do NOT key a
    # transmitter or pop a USB permission dialog on boot.
    {:ok, _} = MinutemodemMobile.Modem.SessionSupervisor.start_link([])

    # ALE process-group scope. Minutewave.ALE.Link / .Transmitter broadcast
    # state changes and events through :pg group {:minutemodem, :rig, rig_id}
    # under this scope, and the Linking screen joins that group to receive
    # them. Global singleton — started once here, not per-rig.
    case :pg.start_link(:minutemodem_pg) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # ALE subsystem supervisor — a per-rig DynamicSupervisor that starts with
    # NO children. The ALE stack (Link/Receiver/Transmitter) is started
    # deliberately later via MinutemodemMobile.ALE.Supervisor.start_stack/2,
    # once a 4G ALE network is active and a self_addr is known. We do not start
    # ALE on boot (no self_addr, and 188-141D only makes sense for a 4G net).
    {:ok, _} = MinutemodemMobile.ALE.Supervisor.start_link([])

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

    Mob.Screen.start_root(MinutemodemMobile.ShellScreen)
    Mob.Dist.ensure_started(node: :"minutemodem_mobile_android@127.0.0.1", cookie: :mob_secret)
  end

  # Override the hardcoded Hamlib defaults with the persisted RigConfig, so the
  # operator's saved CAT options (model/baud/civaddr/ptt/transport) take effect
  # when HamlibStateMachine starts. Falls back to the defaults on any error.
  defp apply_rig_config do
    config = MinutemodemMobile.RigConfig.get()
    {model, conf} = MinutemodemMobile.RigConfig.to_hamlib(config)

    Application.put_env(:minutemodem_mobile, MinutemodemMobile.Rig.HamlibStateMachine,
      model: model,
      conf: conf
    )
  rescue
    _ -> :ok
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
