defmodule TimelessStack.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_stack,
      version: "0.3.5",
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
      {:timeless_metrics, github: "awksedgreep/timeless_metrics", tag: "v3.0.4"},
      {:timeless_logs, github: "awksedgreep/timeless_logs"},
      {:timeless_traces, github: "awksedgreep/timeless_traces"},
      {:ex_openzl, "~> 0.4.5", override: true},
      {:timeless_ui, github: "awksedgreep/timeless_ui", tag: "v0.5.1"},
      {:hackney, "~> 1.20"}
    ]
  end
end
