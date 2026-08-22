defmodule TimelessStack.AlertingEndToEndTest do
  @moduledoc """
  The wiring, not the rule logic.

  timeless_metrics already tests that a rule fires, transitions ok → pending
  → firing → resolved, and formats an ntfy body correctly. None of that ran
  in this deployment, because under `owner: :external` the metrics supervisor
  starts neither the rules database nor the evaluator, and there is no
  in-process store to read.

  This starts the children the stack supplies, ticks the evaluator, and
  asserts a rule stored here is evaluated through the data-plane adapter --
  the band where every failure tonight actually lived: correct components
  connected to nothing.
  """
  use ExUnit.Case, async: false

  @store :alerting_e2e
  @data_dir "/tmp/timeless_alerting_e2e_#{System.unique_integer([:positive])}"

  defmodule StubClient do
    @moduledoc "Stands in for the metrics data plane's HTTP client."
    def range(metric, labels, _from, _to, _step, _aggregate) do
      send(:alerting_e2e_probe, {:range, metric, labels})

      value = Application.get_env(:timeless_stack, :alerting_e2e_value, 0.0)

      {:ok,
       %{
         "metric" => metric,
         "series" => [
           %{"labels" => %{"host" => "web-1"}, "data" => [[System.os_time(:second), value]]}
         ]
       }}
    end
  end

  setup do
    Process.register(self(), :alerting_e2e_probe)
    File.mkdir_p!(@data_dir)

    Application.put_env(:timeless_stack, :metrics_data_plane_client, StubClient)
    Application.put_env(:timeless_metrics, :alert_reader, TimelessStack.MetricsDataPlane)

    start_supervised!({TimelessMetrics.DB, name: :"#{@store}_db", data_dir: @data_dir})

    on_exit(fn ->
      Application.delete_env(:timeless_stack, :metrics_data_plane_client)
      Application.delete_env(:timeless_metrics, :alert_reader)
      Application.delete_env(:timeless_stack, :alerting_e2e_value)
      File.rm_rf!(@data_dir)
    end)

    :ok
  end

  defp create_rule(opts) do
    TimelessMetrics.Alert.create_rule(
      :"#{@store}_db",
      Keyword.merge(
        [
          name: "cpu high",
          metric: "cpu_usage",
          condition: "above",
          threshold: 90.0,
          duration: 0,
          aggregate: "avg",
          webhook_url: nil
        ],
        opts
      )
    )
  end

  test "a rule stored here is evaluated through the data-plane adapter" do
    # The seam that did not exist: no in-process store, so evaluation has to
    # reach the data plane or it cannot happen at all.
    {:ok, _id} = create_rule([])

    assert :ok = TimelessMetrics.Alert.evaluate(@store)

    assert_received {:range, "cpu_usage", _labels}
  end

  test "a breach recorded through the adapter transitions the rule to firing" do
    {:ok, id} = create_rule([])
    Application.put_env(:timeless_stack, :alerting_e2e_value, 99.0)

    assert :ok = TimelessMetrics.Alert.evaluate(@store)

    {:ok, history} = TimelessMetrics.Alert.list_history(:"#{@store}_db", limit: 10)
    assert Enum.any?(history, &(&1.rule_id == id and &1.state == "firing"))
  end

  test "a value below the threshold does not fire" do
    {:ok, id} = create_rule([])
    Application.put_env(:timeless_stack, :alerting_e2e_value, 1.0)

    assert :ok = TimelessMetrics.Alert.evaluate(@store)

    {:ok, history} = TimelessMetrics.Alert.list_history(:"#{@store}_db", limit: 10)
    refute Enum.any?(history, &(&1.rule_id == id and &1.state == "firing"))
  end

  test "the supervised evaluator ticks on its own" do
    # alerting_children/0 returning the right specs is not the same as the
    # evaluator running. A rule that is never evaluated looks exactly like a
    # rule with nothing to report.
    {:ok, _id} = create_rule([])

    start_supervised!(
      {TimelessMetrics.AlertEvaluator,
       name: :"#{@store}_alert_evaluator", store: @store, interval: 100}
    )

    # The evaluator delays its first tick; wait for it rather than sleeping.
    assert_receive {:range, "cpu_usage", _labels}, 10_000
  end

  test "an unreachable data plane does not stop the evaluator" do
    defmodule FailingClient do
      @moduledoc false
      def range(_metric, _labels, _from, _to, _step, _aggregate), do: {:error, :econnrefused}
    end

    {:ok, _id} = create_rule([])
    Application.put_env(:timeless_stack, :metrics_data_plane_client, FailingClient)

    # Must not raise: under a supervisor this would be a restart loop that
    # silently stops all alerting.
    assert :ok = TimelessMetrics.Alert.evaluate(@store)
  end
end
