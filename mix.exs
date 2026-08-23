defmodule TimelessStack.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_stack,
  version: "0.7.17",
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
      {:timeless_metrics, "~> 6.5", override: true},
      {:timeless_logs, "~> 1.9", override: true},
      {:timeless_traces, "~> 1.9", override: true},
      {:ex_openzl, "~> 0.4", override: true},
      # canvas and timeless_ui are not published to hex, so github is their
      # only source; they track main while development is fast (no dot-release
      # tag pins — `mix deps.update` pulls the latest).
      {:timeless_canvas, github: "awksedgreep/timeless_canvas", branch: "main", override: true},
      {:timeless_ui, github: "awksedgreep/timeless_ui", branch: "main", override: true},
      {:timeless_logs_dashboard, "~> 0.7", override: true},
      {:recon, "~> 2.5"}
    ]
  end
end
