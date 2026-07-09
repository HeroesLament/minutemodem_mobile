# syntax=docker/dockerfile:1
#
# MinuteModem CI build image
# ==========================
# Reproduces the pinned host toolchain (.tool-versions) plus the Android
# SDK/NDK/CMake that `mix mob.release --android` and `./gradlew assembleRelease`
# need, and adds the GitHub CLI for publishing the release artifact.
#
# The Elixir pin is load-bearing: building the release with a newer host Elixir
# (1.20+) makes Ecto emit Enum.__in__/2, which the 1.19.5 device runtime does
# not export -> boot crashes, black screen. Keep Elixir at 1.19.x, same as the
# device. (See the note in ../.tool-versions.)
#
# Self-contained: the toolchain versions are baked as ARGs below (kept in sync
# with ../.tool-versions), so the build needs NO files from the repo context —
# just this Dockerfile. Build it anywhere with a matching (amd64) arch.
#
# Build & push to your docker.io repo (amd64 to match the Concourse worker):
#   podman build --platform linux/amd64 -t docker.io/sypher02/minutemodem-ci:latest .
#   podman push  docker.io/sypher02/minutemodem-ci:latest

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    ASDF_DIR=/opt/asdf \
    ASDF_DATA_DIR=/opt/asdf \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    JAVA_HOME=/opt/java

# --- base build deps (Erlang-from-source + Android + misc) ------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates gnupg unzip zip xz-utils \
      build-essential autoconf m4 libncurses-dev libssl-dev \
      libgl1 libxext6 libxrender1 \
      procps file \
    && rm -rf /var/lib/apt/lists/*

# --- Temurin 17 (JDK for Android Gradle Plugin) -----------------------------
# Installed from the Adoptium API tarball rather than apt: the Adoptium apt repo
# is keyed by Debian codename and doesn't reliably carry trixie, and asdf-java's
# exact-version match (temurin-17.0.18+build) is brittle in CI. Gradle/AGP just
# needs *a* JDK 17; the tarball is codename-agnostic and pins the major.
ARG JAVA_MAJOR=17
RUN curl -fsSL "https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR}/ga/linux/x64/jdk/hotspot/normal/eclipse" \
      -o /tmp/jdk.tar.gz \
 && mkdir -p /opt/java \
 && tar -xzf /tmp/jdk.tar.gz -C /opt/java --strip-components=1 \
 && rm /tmp/jdk.tar.gz \
 && "$JAVA_HOME/bin/java" -version

# --- GitHub CLI -------------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# --- asdf plugin prerequisites ----------------------------------------------
# python3: the asdf-zig plugin parses Zig's JSON download index with it. Erlang
# and Elixir plugins don't need it, but zig install dies with `env: python3`.
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

# --- asdf (classic bash edition) + pinned BEAM/zig toolchain ----------------
# v0.14.x is the last shims-based release; the Go rewrite drops asdf.sh and the
# shims-on-PATH model this image relies on.
ARG ASDF_VERSION=v0.14.1
RUN git clone --depth 1 --branch ${ASDF_VERSION} https://github.com/asdf-vm/asdf.git ${ASDF_DIR}
ENV PATH="${ASDF_DIR}/bin:${ASDF_DIR}/shims:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${JAVA_HOME}/bin:${PATH}"

# Skip GUI/Java bits when compiling Erlang -> faster, smaller.
ENV KERL_CONFIGURE_OPTIONS="--without-wx --without-debugger --without-observer --without-et --without-javac"

RUN asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git \
 && asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git \
 && asdf plugin add zig    https://github.com/asdf-community/asdf-zig.git

# Pinned explicitly (NOT bare `asdf install`) so we skip the java line in
# .tool-versions — Java comes from Adoptium above.
ARG ERLANG_VERSION=29.0
ARG ELIXIR_VERSION=1.19.5-otp-28
ARG ZIG_VERSION=0.16.0
RUN asdf install erlang ${ERLANG_VERSION} \
 && asdf install elixir ${ELIXIR_VERSION} \
 && asdf install zig    ${ZIG_VERSION} \
 && asdf global  erlang ${ERLANG_VERSION} \
 && asdf global  elixir ${ELIXIR_VERSION} \
 && asdf global  zig    ${ZIG_VERSION} \
 && asdf reshim

# Hex/rebar into the pinned Elixir.
RUN mix local.hex --force && mix local.rebar --force

# --- Android SDK: platform-34, build-tools 34, NDK 27, cmake 3.22.1 ---------
ARG CMDLINE_TOOLS_VERSION=11076708
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools \
 && curl -fsSL -o /tmp/cmdtools.zip \
      https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip \
 && unzip -q /tmp/cmdtools.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools \
 && mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
 && rm /tmp/cmdtools.zip

RUN yes | sdkmanager --licenses >/dev/null \
 && sdkmanager --install \
      "platform-tools" \
      "platforms;android-34" \
      "build-tools;34.0.0" \
      "ndk;27.2.12479018" \
      "cmake;3.22.1" >/dev/null

# --- Rust toolchain (rustler NIFs: hamlib_ex/native/hamlib_nif, phy_modem) --
# The app's mob.exs supplies the Android cross-compile CC/AR (NDK
# aarch64-linux-android28-clang + llvm-ar) and the crates ship .cargo/config;
# the image only needs cargo + the aarch64-linux-android target. Installed to
# /opt so it's not tied to a specific $HOME.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path \
 && /opt/cargo/bin/rustup target add aarch64-linux-android \
 && chmod -R a+rX /opt/cargo /opt/rustup
ENV PATH="/opt/cargo/bin:${PATH}"

# --- hamlib_nif host build deps ---------------------------------------------
# hamlib_nif's build.rs (via cc-rs + bindgen) needs, for the host mix-compile
# pass: system hamlib headers/lib (found through pkg-config) and libclang (for
# bindgen). The Android build instead links hamlib_ex's committed cross-built
# libhamlib.a. libclang-dev is the LLVM runtime lib only, not the full compiler.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libhamlib-dev pkg-config libclang-dev \
      automake libtool gettext \
 && rm -rf /var/lib/apt/lists/*

# bindgen locates libclang here; mob.exs derives the NDK toolchain from NDK_HOME.
ENV LIBCLANG_PATH=/usr/lib/llvm-19/lib \
    ANDROID_NDK_HOME=${ANDROID_SDK_ROOT}/ndk/27.2.12479018

WORKDIR /work
CMD ["bash"]
