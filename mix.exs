defmodule TimelessStack.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_stack,
      version: "0.3.0",
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
      {:timeless_metrics, path: "../timeless_metrics"},
      {:timeless_logs, github: "awksedgreep/timeless_logs"},
      {:timeless_traces, github: "awksedgreep/timeless_traces"},
      {:ex_openzl, "~> 0.4.0", override: true},
      {:timeless_ui, path: "../timeless_ui"}
    ]
  end
end
