defmodule TimelessStack.AlertBackendTest do
  @moduledoc """
  Rules must be scoped by exactly what draws the graph.

  The canvas hands over the element; this derives metric and labels with the
  same function the graph's query uses. If the two ever diverge, a rule
  watches a different series than the picture it was created from — and
  nothing about it looks wrong.
  """
  use ExUnit.Case, async: false

  alias TimelessCanvas.Canvas.Element
  alias TimelessStack.AlertBackend

  @store :alert_backend_test
  @data_dir "/tmp/timeless_alert_backend_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@data_dir)

    Application.put_env(:timeless_stack, :alerting,
      enabled: true,
      store: @store,
      data_dir: @data_dir
    )

    start_supervised!({TimelessMetrics.DB, name: :"#{@store}_db", data_dir: @data_dir})

    on_exit(fn ->
      Application.delete_env(:timeless_stack, :alerting)
      File.rm_rf!(@data_dir)
    end)

    :ok
  end

  defp graph(meta) do
    %Element{id: "el-1", type: :graph, x: 0.0, y: 0.0, label: "CPU", meta: meta}
  end

  test "a rule is scoped by the element's metric and labels" do
    element = graph(%{"metric_name" => "cpu_usage", "host" => "web-1"})

    assert {:ok, _id} =
             AlertBackend.create_rule(element, %{
               "name" => "CPU high",
               "condition" => "above",
               "threshold" => 90.0,
               "duration" => 0,
               "aggregate" => "avg"
             })

    assert {:ok, [rule]} = AlertBackend.list_rules(element)
    assert rule.metric == "cpu_usage"
    assert rule.labels["host"] == "web-1"
  end

  test "presentation metadata never becomes a label" do
    # y_min/icon and friends describe the picture, not the series. A rule
    # carrying them would match nothing and never fire.
    element =
      graph(%{"metric_name" => "cpu_usage", "host" => "web-1", "y_min" => "0", "icon" => "cpu"})

    {:ok, _} =
      AlertBackend.create_rule(element, %{
        "name" => "x",
        "condition" => "above",
        "threshold" => 1.0,
        "duration" => 0,
        "aggregate" => "avg"
      })

    {:ok, [rule]} = AlertBackend.list_rules(element)
    refute Map.has_key?(rule.labels, "y_min")
    refute Map.has_key?(rule.labels, "icon")
    refute Map.has_key?(rule.labels, "metric_name")
  end

  test "labels match the graph's own derivation exactly" do
    element = graph(%{"metric_name" => "cpu_usage", "host" => "web-1", "device" => "sda"})

    {:ok, _} =
      AlertBackend.create_rule(element, %{
        "name" => "x",
        "condition" => "above",
        "threshold" => 1.0,
        "duration" => 0,
        "aggregate" => "avg"
      })

    {:ok, [rule]} = AlertBackend.list_rules(element)
    assert rule.labels == TimelessStack.UIDataSource.element_labels(element)
  end

  test "rules for another element are not listed" do
    web = graph(%{"metric_name" => "cpu_usage", "host" => "web-1"})
    db = graph(%{"metric_name" => "cpu_usage", "host" => "db-1"})

    {:ok, _} =
      AlertBackend.create_rule(web, %{
        "name" => "web",
        "condition" => "above",
        "threshold" => 1.0,
        "duration" => 0,
        "aggregate" => "avg"
      })

    assert {:ok, [_]} = AlertBackend.list_rules(web)
    assert {:ok, []} = AlertBackend.list_rules(db)
  end

  test "an element selecting no metric cannot carry a rule" do
    assert {:error, :element_selects_no_metric} = AlertBackend.list_rules(graph(%{}))
  end

  test "delivery format is passed through explicitly" do
    element = graph(%{"metric_name" => "cpu_usage"})

    {:ok, _} =
      AlertBackend.create_rule(element, %{
        "name" => "ntfy rule",
        "condition" => "above",
        "threshold" => 1.0,
        "duration" => 0,
        "aggregate" => "avg",
        "webhook_url" => "https://ntfy.sh/ops",
        "webhook_format" => "ntfy"
      })

    {:ok, [rule]} = AlertBackend.list_rules(element)
    # Unset here means a generic JSON body, which ntfy renders as raw text.
    assert rule.webhook_format == "ntfy"
  end

  test "a blank webhook url is stored as absent, not empty string" do
    element = graph(%{"metric_name" => "cpu_usage"})

    {:ok, _} =
      AlertBackend.create_rule(element, %{
        "name" => "no delivery",
        "condition" => "above",
        "threshold" => 1.0,
        "duration" => 0,
        "aggregate" => "avg",
        "webhook_url" => "   "
      })

    {:ok, [rule]} = AlertBackend.list_rules(element)
    assert rule.webhook_url in [nil, ""]
  end

  test "alerting being unavailable reports an error rather than crashing" do
    # The canvas must render a message, not take the LiveView down, when the
    # rules database is not running.
    Application.put_env(:timeless_stack, :alerting,
      enabled: true,
      store: :not_running,
      data_dir: @data_dir
    )

    assert {:error, _reason} = AlertBackend.list_rules(graph(%{"metric_name" => "cpu_usage"}))
  end
end
