defmodule MinutemodemMobile.MixProject do
  use Mix.Project

  def project do
    [
      app: :minutemodem_mobile,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      erlc_paths: ["src"],
      erlc_options: [:debug_info]
    ]
  end

  def application do
    [
      mod: {MinutemodemMobile.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.37"},
      {:minutewave, path: "../minutewave_ex"},
      {:hamlib_ex, path: "../hamlib_ex"},
      {:mob, "~> 0.7"},
      {:mob_dev, "~> 0.5", only: :dev, runtime: false},
      {:ecto_sqlite3, "~> 0.18"},
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end
end
