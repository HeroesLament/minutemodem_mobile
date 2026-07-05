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
#
# hamlib_nif is android-only: it links the NDK-cross-built static libhamlib.a
# (see hamlib_ex/android/hamlib/). On the host, the same crate is built as a
# cdylib through the hamlib_ex path dep against Homebrew's libhamlib, so it
# does not need a static-NIF entry for :host. The crate is vendored at
# native/hamlib_nif (a symlink to deps' published source) because mob_dev's
# cross-compiler only scans <app>/native/<name>/Cargo.toml.
config :mob_dev,
  static_nifs: [
    %{module: :phy_modem, archs: [:all]},
    # arm64 only. mob_dev cross-compiles NIFs for every Android ABI in its
    # build loop regardless of the APK's abiFilters, so this MUST be
    # :android_arm64 (not :android) — otherwise the armv7 pass tries to
    # cross-compile hamlib_nif and fails (no armv7 libhamlib.a / NDK armv7 CC).
    # The APK ships arm64-v8a only (android/app/build.gradle), so the
    # unconditional driver-table entry is correct for every shipped binary.
    %{module: :hamlib_nif, archs: [:android_arm64]}
  ]

# ── hamlib_nif Android cross-compile environment ────────────────────────────
# Unlike pure-Rust NIFs (phy_modem), hamlib_nif's build.rs invokes cc-rs to
# compile the C shim and bindgen to read Hamlib's headers, then statically
# links the NDK-cross-built libhamlib.a. That needs three things Mob's bare
# `cargo rustc` invocation doesn't provide on its own:
#
#   * HAMLIB_INCLUDE_DIR / HAMLIB_LIB_DIR — point build.rs at the cross-built
#     Hamlib install tree (else it falls back to pkg-config → host Homebrew).
#   * CC_<target> / AR_<target> — cc-rs otherwise guesses the compiler name as
#     `aarch64-linux-android-clang` (no API level), which the NDK doesn't ship;
#     the real binary is `aarch64-linux-android28-clang`. Naming it explicitly
#     is what makes the C shim compile for the device.
#
# Paths derive from ANDROID_NDK_HOME (set by the Android command-line tools)
# and the API level Mob targets (28, matching mob_new's minSdk).
ndk_home =
  System.get_env("ANDROID_NDK_HOME") ||
    System.get_env("ANDROID_NDK_ROOT") ||
    raise("ANDROID_NDK_HOME not set — needed for hamlib_nif Android cross-compile")

ndk_host_tag =
  case :os.type() do
    {:unix, :darwin} -> "darwin-x86_64"
    {:unix, _} -> "linux-x86_64"
    _ -> "darwin-x86_64"
  end

ndk_bin = Path.join([ndk_home, "toolchains", "llvm", "prebuilt", ndk_host_tag, "bin"])
hamlib_out = Path.join(File.cwd!(), "../hamlib_ex/android/hamlib/out/aarch64/usr/local")

config :mob_dev,
  nif_build_env: %{
    hamlib_nif: %{
      "HAMLIB_INCLUDE_DIR" => Path.join(hamlib_out, "include"),
      "HAMLIB_LIB_DIR" => Path.join(hamlib_out, "lib"),
      # cc-rs target-scoped tool overrides (underscores match the target triple).
      "CC_aarch64-linux-android" => Path.join(ndk_bin, "aarch64-linux-android28-clang"),
      "AR_aarch64-linux-android" => Path.join(ndk_bin, "llvm-ar")
    }
  }
