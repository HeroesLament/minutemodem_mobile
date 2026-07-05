defmodule MinutemodemMobile.LQAPolicy do
  @moduledoc """
  Per-network LQA participation policy.

  A single operator-facing **mode** (stored as `params["lqa_mode"]`) that
  expands to four independent behaviour flags. The mode is the single source of
  truth — the flags are derived, never stored, so there is no way to persist an
  inconsistent combination.

  ## Modes

    * `"off"`     — LQA disabled entirely.
    * `"rx_only"` — passive / EMCON-friendly: record inbound observations,
      transmit nothing for LQA.
    * `"tx_only"` — beacon: report our measured SNR + sound, don't maintain our
      own table.
    * `"two_way"` — full: record inbound, report SNR, and record peer-reported
      SNR. Default.

  ## Flags

    * `record_rx?`    — persist `:rx` decode observations (how we hear them).
    * `report_snr?`   — put our measured SNR into confirmations (wire behaviour;
      needs a `minutewave` seam to fully honour — see `LQA_POLICY_SPEC.md` §3).
    * `record_tx?`    — persist `:tx` observations (peer-reported SNR of us).
    * `tx_permitted?` — whether keying the transmitter for LQA is allowed at all.

  EMCON (station-wide) overrides this by forcing `tx_permitted?`/`report_snr?`
  false regardless of mode; that is enforced separately at the TX gate.
  """

  @default_mode "two_way"

  # Hardcoded LQA tunables (not operator-exposed for the alpha).
  #
  #   * lookback / decay are inert until AUTO channel-selection (ACS) is wired;
  #     24h / 4h are the sane HF defaults. Re-surface under "Advanced" then.
  #   * retention is fixed — we never keep more than a year of history.
  #
  # Single source of truth for when ACS ranking and the pruner are built.
  @lookback_hours 24
  @decay_hours 4
  @retention_days 365

  @doc "Ranking lookback window in hours (how far back ACS/ranking considers)."
  def lookback_hours, do: @lookback_hours

  @doc "Ranking recency half-life in hours (exponential decay within lookback)."
  def decay_hours, do: @decay_hours

  @doc "History retention in days — rows older than this are pruned."
  def retention_days, do: @retention_days

  @type mode :: String.t()
  @type flags :: %{
          record_rx?: boolean(),
          report_snr?: boolean(),
          record_tx?: boolean(),
          tx_permitted?: boolean()
        }

  @doc "The default mode for a new/unspecified network."
  def default_mode, do: @default_mode

  @doc "The selectable modes as `{label, value}` pairs, for the UI selector."
  def mode_options do
    [{"OFF", "off"}, {"RX", "rx_only"}, {"TX", "tx_only"}, {"2-WAY", "two_way"}]
  end

  @doc """
  Read the mode from a network's `params` map (or a raw map), defaulting to
  `two_way`.
  """
  def mode(%{params: params}) when is_map(params), do: mode(params)
  def mode(params) when is_map(params), do: Map.get(params, "lqa_mode", @default_mode)
  def mode(_), do: @default_mode

  @doc "Derive the four behaviour flags for a mode string."
  @spec flags(mode()) :: flags()
  def flags("off"), do: f(false, false, false, false)
  def flags("rx_only"), do: f(true, false, false, false)
  def flags("tx_only"), do: f(false, true, false, true)
  def flags("two_way"), do: f(true, true, true, true)
  def flags(_unknown), do: flags(@default_mode)

  @doc "Convenience: flags for a network/params map."
  def flags_for(net_or_params), do: net_or_params |> mode() |> flags()

  defp f(rx, snr, tx, tx_ok) do
    %{record_rx?: rx, report_snr?: snr, record_tx?: tx, tx_permitted?: tx_ok}
  end
end
