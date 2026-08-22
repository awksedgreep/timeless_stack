defmodule TimelessStack.AlertingSupervisionTest do
  @moduledoc """
  Alert rules are stored and evaluated by timeless_metrics, whose supervisor
  starts nothing under `owner: :external`. The stack must supply those two
  children itself, or a rule is written, displayed as configured, and never
  evaluated -- which reads exactly like a system with nothing to alert on.
  """
  use ExUnit.Case, async: false

  alias TimelessStack.Application, as: App

  setup do
    original = Application.get_env(:timeless_stack, :alerting)

    on_exit(fn ->
      if original,
        do: Application.put_env(:timeless_stack, :alerting, original),
        else: Application.delete_env(:timeless_stack, :alerting)
    end)

    :ok
  end

  defp children(config) do
    Application.put_env(:timeless_stack, :alerting, config)
    App.alerting_children()
  end

  test "disabled yields no children" do
    assert children(enabled: false) == []
  end

  test "absent configuration yields no children" do
    Application.delete_env(:timeless_stack, :alerting)
    assert App.alerting_children() == []
  end

  test "enabled supervises both the rules database and the evaluator" do
    specs = children(enabled: true, data_dir: "/tmp/alerts", store: :timeless_metrics)

    assert [{TimelessMetrics.DB, db_opts}, {TimelessMetrics.AlertEvaluator, eval_opts}] = specs

    # The evaluator derives its rules database as :"#{store}_db"; these two
    # names must agree or it reads an empty rule set forever.
    assert db_opts[:name] == :timeless_metrics_db
    assert eval_opts[:store] == :timeless_metrics
  end

  test "the rules database never shares a directory with the data plane's" do
    # TimelessMetrics.DB opens <data_dir>/metrics.db. The data plane's own
    # database has that exact name in the metrics directory, so sharing the
    # directory would mean two writers and two migration histories on one file.
    specs = children(enabled: true, data_dir: "/data/alerts", store: :timeless_metrics)
    [{TimelessMetrics.DB, db_opts}, _] = specs

    refute String.ends_with?(db_opts[:data_dir], "/metrics")
    assert db_opts[:data_dir] == "/data/alerts"
  end

  test "the tick interval is configurable and defaults to a minute" do
    [_, {TimelessMetrics.AlertEvaluator, eval_opts}] =
      children(enabled: true, data_dir: "/tmp/alerts")

    assert eval_opts[:interval] == :timer.seconds(60)

    [_, {TimelessMetrics.AlertEvaluator, custom}] =
      children(enabled: true, data_dir: "/tmp/alerts", interval: :timer.seconds(15))

    assert custom[:interval] == :timer.seconds(15)
  end
end
