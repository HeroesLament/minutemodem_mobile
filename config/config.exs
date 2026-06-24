import Config

# Minutewave protocol stack delegates DSP calls to this NIF module,
# which links against milwave-rs via the local native/phy_modem crate.
config :minutewave, phy_modem_nif: MinutemodemMobile.Nifs.PhyModem

# Minutewave audio backend: loopback for development/testing.
config :minutewave, audio_backend: MinutemodemMobile.Audio.LoopbackBackend

config :minutewave, rig_control: MinutemodemMobile.Rig.StubControl

# Ecto: register the repo so `mix ecto.*` tasks can find it. At runtime the
# repo is started manually in MinutemodemMobile.App.on_start/0 (Mob's
# start_clean boot doesn't start path-dep applications), and the database
# path is resolved there from MOB_DATA_DIR. This dev-only database path is
# used by `mix ecto.migrate` / `mix ecto.create` on the host.
config :minutemodem_mobile, ecto_repos: [MinutemodemMobile.Repo]

config :minutemodem_mobile, MinutemodemMobile.Repo,
  database: Path.expand("../priv/repo/dev.db", __DIR__),
  pool_size: 1
