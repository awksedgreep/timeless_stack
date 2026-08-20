defmodule TimelessStack.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_stack,
  version: "0.7.8",
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
      {:timeless_canvas, github: "awksedgreep/timeless_canvas", tag: "v0.5.1", override: true},
      {:timeless_ui, github: "awksedgreep/timeless_ui", tag: "v0.9.15", override: true},
      # Git tag rather than hex: v0.7.21 (remote live tail) ships in this
      # image ahead of its hex publish, which needs the operator's key.
      {:timeless_logs_dashboard,
       github: "awksedgreep/timeless_logs_dashboard", tag: "v0.7.21", override: true},
      {:hackney, "~> 1.20"},
      {:recon, "~> 2.5"}
    ]
  end
end
