defmodule MinutemodemMobile.Nifs.PhyModem do
  @moduledoc """
  Elixir NIF surface for the milwave-rs MIL-STD-188-110D modem.

  Rust source lives at `native/phy_modem/src/lib.rs`. That crate depends
  on `wavecore-rs` (DSP primitives) and `milwave-rs` (waveform engine),
  both pulled via git deps in `native/phy_modem/Cargo.toml`.
  """

  use Rustler, otp_app: :minutemodem_mobile, crate: "phy_modem"

  # ──────────────────────────────────────────────────────────────────────
  # UnifiedModulator
  # ──────────────────────────────────────────────────────────────────────

  def unified_mod_new(_constellation, _sample_rate, _symbol_rate, _carrier_freq),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_modulate(_modulator, _symbols),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_modulate_mixed(_modulator, _tagged_symbols),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_set_constellation(_modulator, _constellation),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_get_constellation(_modulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_flush(_modulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_reset(_modulator),
    do: :erlang.nif_error(:nif_not_loaded)

  # ──────────────────────────────────────────────────────────────────────
  # UnifiedDemodulator
  # ──────────────────────────────────────────────────────────────────────

  def unified_demod_new(_constellation, _sample_rate, _symbol_rate, _carrier_freq),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_iq(_demodulator, _samples),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_symbols(_demodulator, _samples),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_eq_iq(_demodulator, _samples),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_set_constellation(_demodulator, _constellation),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_reset(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  # ──────────────────────────────────────────────────────────────────────
  # Zero-copy binary seam (s16le PCM in/out)
  #
  # Realtime audio path variants: PCM crosses the NIF boundary as an Erlang
  # binary, not a list of integers, to avoid one boxed term per sample
  # (~48k/sec/direction) of allocator + GC load. Symbols stay lists (small,
  # baud-rate cardinality).
  # ──────────────────────────────────────────────────────────────────────

  def unified_demod_symbols_bin(_demodulator, _samples_bin),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_iq_bin(_demodulator, _samples_bin),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_modulate_bin(_modulator, _symbols),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_mod_flush_bin(_modulator),
    do: :erlang.nif_error(:nif_not_loaded)

  # ──────────────────────────────────────────────────────────────────────
  # DFE (Decision Feedback Equalizer)
  # ──────────────────────────────────────────────────────────────────────

  def unified_demod_new_with_eq(_constellation, _sample_rate, _ff_taps, _fb_taps, _mu, _symbol_rate, _carrier_freq),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_new_hf(_constellation, _sample_rate, _symbol_rate, _carrier_freq),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_set_training(_demodulator, _symbols),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_reset_eq(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_mse(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_has_eq(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_enable_eq(_demodulator, _ff_taps, _fb_taps, _mu),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_disable_eq(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_eq_mode(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  # ──────────────────────────────────────────────────────────────────────
  # Telemetry (PLL + DFE)
  # ──────────────────────────────────────────────────────────────────────

  def unified_demod_enable_telemetry(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_take_telemetry(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_lock_detect(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_set_block_size(_demodulator, _size),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_get_block_size(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_enable_dfe_telemetry(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  def unified_demod_take_dfe_telemetry(_demodulator),
    do: :erlang.nif_error(:nif_not_loaded)

  # ──────────────────────────────────────────────────────────────────────
  # Walsh Correlator
  # ──────────────────────────────────────────────────────────────────────

  def walsh_correlator_new(_n_phases, _n_passes),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_decode(_correlator, _descrambled_iq, _raw_iq, _scramble_offsets),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_decode_soft(_correlator, _descrambled_iq, _raw_iq, _scramble_offsets),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_decode_diagnostic(
        _correlator,
        _descrambled_iq,
        _raw_iq,
        _scramble_offsets
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_enable_telemetry(_correlator),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_correlator_take_telemetry(_correlator),
    do: :erlang.nif_error(:nif_not_loaded)

  def walsh_turbo_decode(
        _correlator,
        _descrambled_iq,
        _raw_iq,
        _scramble_offsets,
        _n_iterations
      ),
      do: :erlang.nif_error(:nif_not_loaded)
end
