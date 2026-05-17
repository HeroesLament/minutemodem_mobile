//! NIF wrapper for milwave-rs.
//!
//! Exposes the MIL-STD-188-110D modem surface to Elixir via Rustler. All
//! actual DSP lives in `milwave-rs` (which composes `wavecore-rs`
//! primitives); this crate is a marshaling layer that:
//!
//! - Decodes atoms / lists / binaries / numbers from BEAM terms
//! - Holds long-lived state inside `ResourceArc<...>` wrappers
//! - Calls the right milwave-rs method
//! - Encodes the result back to BEAM
//!
//! ## Resource lifetimes
//!
//! `UnifiedModulatorResource`, `UnifiedDemodulatorResource`, and
//! `WalshCorrelatorResource` all wrap their inner type in a `Mutex`. The
//! mutex isn't load-bearing — BEAM serialises NIF calls on the same
//! ResourceArc, so there's no real concurrent access. The mutex exists
//! because `ResourceArc<T>` requires `T: Sync` and our inner types
//! aren't `Sync` by themselves.
//!
//! ## Rustler 0.37 conventions
//!
//! - `#[rustler::nif]` auto-registers via the `inventory` crate.
//! - `#[rustler::resource_impl]` on an `impl Resource for X {}` block
//!   auto-registers the resource type at module load. No `load = ...`
//!   callback needed.
//! - `rustler::init!("Elixir.Module.Name")` — no function list, no
//!   load_data, no resource list. All discovery is compile-time.

use rustler::{Atom, NifResult, Resource, ResourceArc};
use std::sync::Mutex;

use milwave_rs::unified::{
    ConstellationType, DFEConfig, EqMode, UnifiedDemodulator, UnifiedModulator,
};
use milwave_rs::walsh::WalshCorrelator;

// ============================================================================
// Atoms
// ============================================================================

rustler::atoms! {
    ok,
    error,
    none,
    // Modulation types
    bpsk,
    qpsk,
    psk8,
    qam16,
    qam32,
    qam64,
    // Equalizer modes
    cma,
    dd,
}

fn atom_to_constellation(atom: Atom) -> Result<ConstellationType, &'static str> {
    if atom == bpsk() {
        Ok(ConstellationType::Bpsk)
    } else if atom == qpsk() {
        Ok(ConstellationType::Qpsk)
    } else if atom == psk8() {
        Ok(ConstellationType::Psk8)
    } else if atom == qam16() {
        Ok(ConstellationType::Qam16)
    } else if atom == qam32() {
        Ok(ConstellationType::Qam32)
    } else if atom == qam64() {
        Ok(ConstellationType::Qam64)
    } else {
        Err("unsupported modulation type")
    }
}

fn constellation_to_atom(ct: ConstellationType) -> Atom {
    match ct {
        ConstellationType::Bpsk => bpsk(),
        ConstellationType::Qpsk => qpsk(),
        ConstellationType::Psk8 => psk8(),
        ConstellationType::Qam16 => qam16(),
        ConstellationType::Qam32 => qam32(),
        ConstellationType::Qam64 => qam64(),
    }
}

// ============================================================================
// Resources
// ============================================================================

pub struct UnifiedModulatorResource {
    pub inner: Mutex<UnifiedModulator>,
}

#[rustler::resource_impl]
impl Resource for UnifiedModulatorResource {}

pub struct UnifiedDemodulatorResource {
    pub inner: Mutex<UnifiedDemodulator>,
}

#[rustler::resource_impl]
impl Resource for UnifiedDemodulatorResource {}

pub struct WalshCorrelatorResource {
    pub inner: Mutex<WalshCorrelator>,
}

#[rustler::resource_impl]
impl Resource for WalshCorrelatorResource {}

// ============================================================================
// UnifiedModulator NIFs (7)
// ============================================================================

/// Create a unified modulator (default 2400 baud, 1800 Hz carrier).
#[rustler::nif]
pub fn unified_mod_new(
    modulation: Atom,
    sample_rate: u32,
    symbol_rate: Option<u32>,
    carrier_freq: Option<f64>,
) -> NifResult<ResourceArc<UnifiedModulatorResource>> {
    let symbol_rate = symbol_rate.unwrap_or(2400);
    let carrier_freq = carrier_freq.unwrap_or(1800.0);
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    let modulator = UnifiedModulator::new(constellation, sample_rate, symbol_rate, carrier_freq);
    Ok(ResourceArc::new(UnifiedModulatorResource {
        inner: Mutex::new(modulator),
    }))
}

/// Modulate a frame of symbols using the current constellation.
#[rustler::nif]
pub fn unified_mod_modulate(
    modulator: ResourceArc<UnifiedModulatorResource>,
    symbols: Vec<u8>,
) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(state.modulate(&symbols))
}

/// Modulate with per-symbol constellation tagging (for 188-110D mini-probes
/// interleaved with QAM data symbols mid-frame).
#[rustler::nif]
pub fn unified_mod_modulate_mixed(
    modulator: ResourceArc<UnifiedModulatorResource>,
    symbols: Vec<(u8, Atom)>,
) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    let mixed: Result<Vec<_>, _> = symbols
        .into_iter()
        .map(|(sym, atom)| atom_to_constellation(atom).map(|ct| (sym, ct)))
        .collect();
    let mixed = mixed.map_err(|e| rustler::Error::Term(Box::new(e)))?;

    Ok(state.modulate_mixed(&mixed))
}

/// Switch the modulator's constellation without resetting filter state.
#[rustler::nif]
pub fn unified_mod_set_constellation(
    modulator: ResourceArc<UnifiedModulatorResource>,
    modulation: Atom,
) -> NifResult<Atom> {
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    state.set_constellation(constellation);
    Ok(ok())
}

/// Get the modulator's current constellation.
#[rustler::nif]
pub fn unified_mod_get_constellation(
    modulator: ResourceArc<UnifiedModulatorResource>,
) -> NifResult<Atom> {
    let state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(constellation_to_atom(state.constellation()))
}

/// Flush the RRC filter tail (2 * RRC_SPAN zero symbols).
#[rustler::nif]
pub fn unified_mod_flush(
    modulator: ResourceArc<UnifiedModulatorResource>,
) -> NifResult<Vec<i16>> {
    let mut state = modulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(state.flush())
}

/// Reset modulator state (filter history + NCO phase).
#[rustler::nif]
pub fn unified_mod_reset(modulator: ResourceArc<UnifiedModulatorResource>) -> Atom {
    if let Ok(mut state) = modulator.inner.lock() {
        state.reset();
    }
    ok()
}

// ============================================================================
// UnifiedDemodulator NIFs (6)
// ============================================================================

/// Create a unified demodulator (default 2400 baud, 1800 Hz carrier, no
/// equalizer).
#[rustler::nif]
pub fn unified_demod_new(
    modulation: Atom,
    sample_rate: u32,
    symbol_rate: Option<u32>,
    carrier_freq: Option<f64>,
) -> NifResult<ResourceArc<UnifiedDemodulatorResource>> {
    let symbol_rate = symbol_rate.unwrap_or(2400);
    let carrier_freq = carrier_freq.unwrap_or(1800.0);
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    let demodulator = UnifiedDemodulator::new(constellation, sample_rate, symbol_rate, carrier_freq);
    Ok(ResourceArc::new(UnifiedDemodulatorResource {
        inner: Mutex::new(demodulator),
    }))
}

/// Demodulate audio samples to per-symbol I/Q pairs (no slicing).
#[rustler::nif]
pub fn unified_demod_iq(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    samples: Vec<i16>,
) -> NifResult<Vec<(f64, f64)>> {
    let mut state = demodulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(state.demodulate_iq(&samples))
}

/// Demodulate audio samples to hard symbol decisions.
#[rustler::nif]
pub fn unified_demod_symbols(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    samples: Vec<i16>,
) -> NifResult<Vec<u8>> {
    let mut state = demodulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(state.demodulate(&samples))
}

/// Demodulate to equalized I/Q (runs DFE if attached; otherwise raw I/Q).
#[rustler::nif]
pub fn unified_demod_eq_iq(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    samples: Vec<i16>,
) -> NifResult<Vec<(f64, f64)>> {
    let mut state = demodulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok(state.demodulate_eq_iq(&samples))
}

/// Switch the demodulator's constellation (propagates to DFE if attached).
#[rustler::nif]
pub fn unified_demod_set_constellation(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    modulation: Atom,
) -> NifResult<Atom> {
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    let mut state = demodulator
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    state.set_constellation(constellation);
    Ok(ok())
}

/// Reset all demodulator state (PLL, timing, filter, equalizer).
#[rustler::nif]
pub fn unified_demod_reset(demodulator: ResourceArc<UnifiedDemodulatorResource>) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.reset();
    }
    ok()
}

// ============================================================================
// Equalizer NIFs (9)
// ============================================================================

/// Create a demodulator with a custom-configured DFE.
#[rustler::nif]
pub fn unified_demod_new_with_eq(
    modulation: Atom,
    sample_rate: u32,
    ff_taps: usize,
    fb_taps: usize,
    mu: f64,
    symbol_rate: Option<u32>,
    carrier_freq: Option<f64>,
) -> NifResult<ResourceArc<UnifiedDemodulatorResource>> {
    let symbol_rate = symbol_rate.unwrap_or(2400);
    let carrier_freq = carrier_freq.unwrap_or(1800.0);
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    let config = DFEConfig {
        ff_taps,
        fb_taps,
        mu,
        mu_cma: mu / 6.0,
        leakage: 0.9999,
        update_threshold: 0.1,
        cma_to_dd_threshold: 0.3,
        cma_min_symbols: 50,
    };

    let demodulator =
        UnifiedDemodulator::with_equalizer(constellation, sample_rate, symbol_rate, carrier_freq, config);

    Ok(ResourceArc::new(UnifiedDemodulatorResource {
        inner: Mutex::new(demodulator),
    }))
}

/// Create a demodulator with the default HF skywave DFE preset.
#[rustler::nif]
pub fn unified_demod_new_hf(
    modulation: Atom,
    sample_rate: u32,
    symbol_rate: Option<u32>,
    carrier_freq: Option<f64>,
) -> NifResult<ResourceArc<UnifiedDemodulatorResource>> {
    let symbol_rate = symbol_rate.unwrap_or(2400);
    let carrier_freq = carrier_freq.unwrap_or(1800.0);
    let constellation = atom_to_constellation(modulation)
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;
    let demodulator =
        UnifiedDemodulator::with_hf_equalizer(constellation, sample_rate, symbol_rate, carrier_freq);
    Ok(ResourceArc::new(UnifiedDemodulatorResource {
        inner: Mutex::new(demodulator),
    }))
}

/// Provide known training symbols for fast supervised DFE acquisition.
#[rustler::nif]
pub fn unified_demod_set_training(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    symbols: Vec<u8>,
) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.set_training_symbols(symbols);
    }
    ok()
}

/// Reset DFE state (clears taps + reverts to CMA mode); does not reset PLL.
#[rustler::nif]
pub fn unified_demod_reset_eq(demodulator: ResourceArc<UnifiedDemodulatorResource>) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.reset_equalizer();
    }
    ok()
}

/// Get DFE mean squared error (0.0 if no equalizer attached).
#[rustler::nif]
pub fn unified_demod_mse(demodulator: ResourceArc<UnifiedDemodulatorResource>) -> f64 {
    demodulator
        .inner
        .lock()
        .map(|state| state.equalizer_mse().unwrap_or(0.0))
        .unwrap_or(0.0)
}

/// Check whether a DFE is attached to this demodulator.
#[rustler::nif]
pub fn unified_demod_has_eq(demodulator: ResourceArc<UnifiedDemodulatorResource>) -> bool {
    demodulator
        .inner
        .lock()
        .map(|state| state.has_equalizer())
        .unwrap_or(false)
}

/// Attach (or replace) a DFE on an existing demodulator.
#[rustler::nif]
pub fn unified_demod_enable_eq(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    ff_taps: usize,
    fb_taps: usize,
    mu: f64,
) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        let config = DFEConfig {
            ff_taps,
            fb_taps,
            mu,
            mu_cma: mu / 6.0,
            leakage: 0.9999,
            update_threshold: 0.1,
            cma_to_dd_threshold: 0.3,
            cma_min_symbols: 50,
        };
        state.enable_equalizer(config);
    }
    ok()
}

/// Detach the DFE from this demodulator.
#[rustler::nif]
pub fn unified_demod_disable_eq(demodulator: ResourceArc<UnifiedDemodulatorResource>) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.disable_equalizer();
    }
    ok()
}

/// Get DFE operating mode (:cma, :dd, or :none if no equalizer).
#[rustler::nif]
pub fn unified_demod_eq_mode(demodulator: ResourceArc<UnifiedDemodulatorResource>) -> Atom {
    demodulator
        .inner
        .lock()
        .map(|state| match state.equalizer_mode() {
            Some(EqMode::CMA) => cma(),
            Some(EqMode::DD) => dd(),
            None => none(),
        })
        .unwrap_or_else(|_| none())
}

// ============================================================================
// PLL / DFE Telemetry NIFs (7)
// ============================================================================

/// Enable PLL telemetry recording (per-symbol snapshots).
#[rustler::nif]
pub fn unified_demod_enable_telemetry(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.enable_telemetry();
    }
    ok()
}

/// Drain the PLL telemetry buffer.
///
/// Returns `[{symbol_idx, phase, freq, integrator, phase_error, mag_sq, lock_detect}]`.
#[rustler::nif]
pub fn unified_demod_take_telemetry(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> Vec<(usize, f64, f64, f64, f64, f64, f64)> {
    demodulator
        .inner
        .lock()
        .map(|mut state| {
            state
                .take_telemetry()
                .into_iter()
                .map(|t| {
                    (
                        t.symbol_idx,
                        t.phase,
                        t.freq,
                        t.integrator,
                        t.phase_error,
                        t.mag_sq,
                        t.lock_detect,
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Get current PLL lock indicator (EMA of cos(8·phase_error); +1 = locked).
#[rustler::nif]
pub fn unified_demod_lock_detect(demodulator: ResourceArc<UnifiedDemodulatorResource>) -> f64 {
    demodulator
        .inner
        .lock()
        .map(|state| state.lock_detect())
        .unwrap_or(0.0)
}

/// Set the PLL block-phase-estimator block size (symbols per phase update).
#[rustler::nif]
pub fn unified_demod_set_block_size(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
    size: usize,
) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.set_phase_block_size(size);
    }
    ok()
}

/// Get the current PLL phase-estimator block size.
#[rustler::nif]
pub fn unified_demod_get_block_size(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> usize {
    demodulator
        .inner
        .lock()
        .map(|state| state.phase_block_size())
        .unwrap_or(0)
}

/// Enable DFE telemetry recording (per-symbol DFE snapshots).
#[rustler::nif]
pub fn unified_demod_enable_dfe_telemetry(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> Atom {
    if let Ok(mut state) = demodulator.inner.lock() {
        state.enable_dfe_telemetry();
    }
    ok()
}

/// Drain the DFE telemetry buffer.
///
/// Returns `[{symbol_idx, mse, cma_cost, out_mag_sq, in_mag_sq, tap_energy, mode}]`
/// where `mode` is `0` for CMA, `1` for DD.
#[rustler::nif]
pub fn unified_demod_take_dfe_telemetry(
    demodulator: ResourceArc<UnifiedDemodulatorResource>,
) -> Vec<(u64, f64, f64, f64, f64, f64, u8)> {
    demodulator
        .inner
        .lock()
        .map(|mut state| {
            state
                .take_dfe_telemetry()
                .into_iter()
                .map(|t| {
                    (
                        t.symbol_idx,
                        t.mse,
                        t.cma_cost,
                        t.out_mag_sq,
                        t.in_mag_sq,
                        t.tap_energy,
                        t.mode,
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

// ============================================================================
// Walsh Correlator NIFs (6)
// ============================================================================

/// Create a Walsh correlator with the given number of phase hypotheses
/// and CMA equalization passes.
#[rustler::nif]
pub fn walsh_correlator_new(
    n_phases: usize,
    n_passes: usize,
) -> ResourceArc<WalshCorrelatorResource> {
    ResourceArc::new(WalshCorrelatorResource {
        inner: Mutex::new(WalshCorrelator::new(n_phases, n_passes)),
    })
}

/// Decode a frame to hard quadbits + per-block scores.
///
/// Returns `(quadbits, scores)`.
#[rustler::nif]
pub fn walsh_correlator_decode(
    correlator: ResourceArc<WalshCorrelatorResource>,
    descrambled_iq: Vec<(f64, f64)>,
    raw_iq: Vec<(f64, f64)>,
    scramble_offsets: Vec<u8>,
) -> (Vec<u8>, Vec<f64>) {
    correlator
        .inner
        .lock()
        .map(|mut state| state.decode_frame(&descrambled_iq, &raw_iq, &scramble_offsets))
        .unwrap_or_else(|_| (vec![], vec![]))
}

/// Decode a frame returning soft per-bit LLRs.
///
/// Returns `(quadbits, scores, soft_llrs)`. 4 LLRs per quadbit, MSB first.
/// Positive = bit more likely 1, negative = more likely 0.
#[rustler::nif]
pub fn walsh_correlator_decode_soft(
    correlator: ResourceArc<WalshCorrelatorResource>,
    descrambled_iq: Vec<(f64, f64)>,
    raw_iq: Vec<(f64, f64)>,
    scramble_offsets: Vec<u8>,
) -> (Vec<u8>, Vec<f64>, Vec<f64>) {
    correlator
        .inner
        .lock()
        .map(|mut state| state.decode_frame_soft(&descrambled_iq, &raw_iq, &scramble_offsets))
        .unwrap_or_else(|_| (vec![], vec![], vec![]))
}

/// Decode a frame returning quadbits + scores + soft LLRs + per-block
/// diagnostics `(evm_raw_db, evm_eq_db, isi_ratio, residual_fit)`.
#[rustler::nif]
pub fn walsh_correlator_decode_diagnostic(
    correlator: ResourceArc<WalshCorrelatorResource>,
    descrambled_iq: Vec<(f64, f64)>,
    raw_iq: Vec<(f64, f64)>,
    scramble_offsets: Vec<u8>,
) -> (Vec<u8>, Vec<f64>, Vec<f64>, Vec<(f64, f64, f64, f64)>) {
    correlator
        .inner
        .lock()
        .map(|mut state| {
            state.decode_frame_diagnostic(&descrambled_iq, &raw_iq, &scramble_offsets)
        })
        .unwrap_or_else(|_| (vec![], vec![], vec![], vec![]))
}

/// Enable per-decode telemetry recording.
#[rustler::nif]
pub fn walsh_correlator_enable_telemetry(
    correlator: ResourceArc<WalshCorrelatorResource>,
) -> Atom {
    if let Ok(mut state) = correlator.inner.lock() {
        state.enable_telemetry();
    }
    ok()
}

/// Drain telemetry from the most recent decode.
///
/// Returns `(pass_scores, pass_used, avg_score, min_score, phase_spread, blocks)`
/// where each block tuple is `(score, phase, channel_mag, channel_phase, eq_gain)`.
#[rustler::nif]
pub fn walsh_correlator_take_telemetry(
    correlator: ResourceArc<WalshCorrelatorResource>,
) -> (Vec<f64>, usize, f64, f64, f64, Vec<(f64, f64, f64, f64, f64)>) {
    correlator
        .inner
        .lock()
        .map(|mut state| match state.take_telemetry() {
            Some(t) => {
                let blocks: Vec<(f64, f64, f64, f64, f64)> = t
                    .blocks
                    .iter()
                    .map(|b| (b.score, b.phase, b.channel_mag, b.channel_phase, b.eq_gain))
                    .collect();
                (
                    t.pass_scores,
                    t.pass_used,
                    t.avg_score,
                    t.min_score,
                    t.phase_spread,
                    blocks,
                )
            }
            None => (vec![], 0, 0.0, 0.0, 0.0, vec![]),
        })
        .unwrap_or_else(|_| (vec![], 0, 0.0, 0.0, 0.0, vec![]))
}

// ============================================================================
// Turbo Decode NIF (1)
// ============================================================================

/// Iterative pass-loop equalization + BCJR turbo decode.
///
/// Delegates to `WalshCorrelator::turbo_decode_frame`, which owns the
/// pass-loop algorithm (previously implemented here, now in milwave-rs
/// proper for testability).
///
/// Returns `(hard_bits, soft_dibit_llrs, iteration_scores)`.
#[rustler::nif]
pub fn walsh_turbo_decode(
    correlator: ResourceArc<WalshCorrelatorResource>,
    descrambled_iq: Vec<(f64, f64)>,
    raw_iq: Vec<(f64, f64)>,
    scramble_offsets: Vec<u8>,
    n_iterations: usize,
) -> (Vec<u8>, Vec<(f64, f64)>, Vec<f64>) {
    correlator
        .inner
        .lock()
        .map(|mut state| {
            state.turbo_decode_frame(&descrambled_iq, &raw_iq, &scramble_offsets, n_iterations)
        })
        .unwrap_or_else(|_| (vec![], vec![], vec![]))
}

// ============================================================================
// NIF init
// ============================================================================

rustler::init!("Elixir.MinutemodemMobile.Nifs.PhyModem");
