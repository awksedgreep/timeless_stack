defmodule TimelessStack.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_stack,
      version: "0.4.1",
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
      ]
    ]
  end

  defp deps do
    [
      {:timeless_metrics, github: "awksedgreep/timeless_metrics", branch: "main"},
      {:timeless_logs, github: "awksedgreep/timeless_logs", branch: "main"},
      {:timeless_traces, github: "awksedgreep/timeless_traces", branch: "main"},
      {:ex_openzl, "~> 0.4.5", override: true},
      {:timeless_canvas, github: "awksedgreep/timeless_canvas", tag: "v0.4.0", override: true},
      {:timeless_ui, github: "awksedgreep/timeless_ui", tag: "v0.9.2"},
      {:hackney, "~> 1.20"},
      {:recon, "~> 2.5"}
    ]
  end
end
