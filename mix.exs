defmodule TimelessStack.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_stack,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TimelessStack.Application, []}
    ]
  end

  defp deps do
    [
      {:timeless_metrics, github: "awksedgreep/timeless_metrics", tag: "v0.6.4"},
      {:timeless_logs, github: "awksedgreep/timeless_logs"},
      {:timeless_traces, github: "awksedgreep/timeless_traces"},
      # Override: logs/traces pull ex_openzl from GitHub, needs consistent ref
      {:ex_openzl, github: "awksedgreep/ex_openzl", ref: "25bcbf9", submodules: true,
       override: true}
    ]
  end
end
