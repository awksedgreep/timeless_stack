defmodule TimelessStack.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_stack,
      version: "0.6.12",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TimelessStack.Application, []}
    ]
  end

  defp releases do
    [
      timeless_stack: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  defp aliases do
    [
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.deploy": [
        "tailwind timeless_ui --minify",
        "esbuild timeless_ui --minify",
        "phx.digest"
      ],
      test: [
        "ecto.migrate --quiet -r TimelessUI.Repo --migrations-path deps/timeless_ui/priv/repo/migrations",
        "test"
      ]
    ]
  end

  defp deps do
    [
      {:timeless_metrics,
       github: "awksedgreep/timeless_metrics",
       branch: "release/rust-telemetry-data-plane",
       override: true},
      {:timeless_logs,
       github: "awksedgreep/timeless_logs",
       branch: "release/rust-telemetry-data-plane",
       override: true},
      {:timeless_traces,
       github: "awksedgreep/timeless_traces",
       branch: "release/rust-telemetry-data-plane",
       override: true},
      {:ex_openzl, "~> 0.4", override: true},
      {:timeless_canvas, github: "awksedgreep/timeless_canvas", override: true},
      {:timeless_ui,
       github: "awksedgreep/timeless_ui",
       branch: "release/rust-telemetry-data-plane",
       override: true},
      {:hackney, "~> 1.20"},
      {:recon, "~> 2.5"}
    ]
  end
end
