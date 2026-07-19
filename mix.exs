defmodule TimelessStack.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_stack,
      version: "0.6.10",
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
      {:timeless_metrics, "~> 6.0"},
      {:timeless_logs, "~> 1.4"},
      {:timeless_traces, "~> 1.3"},
      {:ex_openzl, "~> 0.4", override: true},
      {:timeless_canvas, github: "awksedgreep/timeless_canvas", override: true},
      {:timeless_ui, github: "awksedgreep/timeless_ui"},
      {:hackney, "~> 1.20"},
      {:recon, "~> 2.5"}
    ]
  end
end
