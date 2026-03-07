defmodule TimelessStack.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_stack,
      version: "0.3.29",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TimelessStack.Application, []}
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
      {:timeless_metrics, github: "awksedgreep/timeless_metrics", tag: "v3.2.0"},
      {:timeless_logs, github: "awksedgreep/timeless_logs", tag: "v1.1.0"},
      {:timeless_traces, github: "awksedgreep/timeless_traces", tag: "v1.1.0"},
      {:ex_openzl, "~> 0.4.5", override: true},
      {:timeless_canvas, github: "awksedgreep/timeless_canvas", tag: "v0.2.0"},
      {:timeless_ui, github: "awksedgreep/timeless_ui", tag: "v0.8.3"},
      {:hackney, "~> 1.20"}
    ]
  end
end
