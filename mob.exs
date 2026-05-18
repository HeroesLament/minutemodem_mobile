# mob.exs — Mob build environment configuration.
# Set these paths for your machine. Not committed to version control.
# (Add mob.exs to .gitignore if you share this project.)
#
# OTP runtimes for Android and iOS are downloaded automatically by `mix mob.install`.

import Config

config :mob_dev,
  # Path to the mob library repo (native source files for iOS/Android builds).
  mob_dir: Path.join(File.cwd!(), "deps/mob"),

  # Path to your Elixir lib dir (e.g. ~/.local/share/mise/installs/elixir/1.18.4-otp-28/lib).
  elixir_lib: System.get_env("MOB_ELIXIR_LIB", :code.lib_dir(:elixir) |> to_string() |> Path.dirname())

# Bundle ID for the app (used by Android applicationId + future iOS bundle identifier).
config :mob_dev, bundle_id: "com.example.minutemodem_mobile"

# Statically-linked NIFs. mob_dev cross-compiles these into the app binary
# at deploy time and generates priv/generated/driver_tab_*.zig so the
# embedded BEAM can find them via dlsym at NIF load time.
config :mob_dev,
  static_nifs: [%{module: :phy_modem, archs: [:all]}]
