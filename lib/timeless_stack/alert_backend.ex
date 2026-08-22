defmodule TimelessStack.AlertBackend do
  @moduledoc """
  Canvas alerting over `TimelessMetrics.Alert`.

  Rules live in the rules database this application supervises (see
  `TimelessStack.Application`), and are evaluated there against the metrics
  data plane. The canvas hands over the element; the metric and labels are
  derived here using exactly the derivation that draws the graph, so a rule
  can never end up watching a different series than the picture it was
  created from.
  """

  @behaviour TimelessCanvas.AlertSource

  alias TimelessCanvas.Canvas.Element

  @impl true
  def list_rules(%Element{} = element) do
    with {:ok, metric, labels} <- selector(element),
         {:ok, rules} <- safely(fn -> TimelessMetrics.Alert.list_rules(db()) end) do
      {:ok, Enum.filter(rules, &matches?(&1, metric, labels))}
    end
  end

  @impl true
  def create_rule(%Element{} = element, attrs) do
    with {:ok, metric, labels} <- selector(element) do
      safely(fn ->
        TimelessMetrics.Alert.create_rule(db(),
          name: attrs["name"],
          metric: metric,
          labels: labels,
          condition: attrs["condition"] || "above",
          threshold: attrs["threshold"],
          duration: attrs["duration"] || 0,
          aggregate: attrs["aggregate"] || "avg",
          webhook_url: presence(attrs["webhook_url"]),
          # Explicit, never inferred: the generic body posted to an ntfy topic
          # arrives as unreadable raw JSON.
          webhook_format: presence(attrs["webhook_format"])
        )
      end)
    end
  end

  @impl true
  def update_rule(id, attrs) do
    updates =
      attrs
      |> Enum.flat_map(fn
        {"enabled", value} -> [enabled: value]
        {"threshold", value} -> [threshold: value]
        {"condition", value} -> [condition: value]
        {"duration", value} -> [duration: value]
        {"aggregate", value} -> [aggregate: value]
        {"name", value} -> [name: value]
        {"webhook_url", value} -> [webhook_url: value]
        {"webhook_format", value} -> [webhook_format: value]
        _ -> []
      end)

    case safely(fn -> TimelessMetrics.Alert.update_rule(db(), id, updates) end) do
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  @impl true
  def delete_rule(id) do
    case safely(fn -> TimelessMetrics.Alert.delete_rule(db(), id) end) do
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  @impl true
  def delivery_formats do
    [{"ntfy", "ntfy"}, {"generic", "Generic JSON"}]
  end

  # The element's own selector, derived the same way the graph's query is.
  defp selector(%Element{meta: meta} = element) do
    case meta["metric_name"] do
      metric when is_binary(metric) and metric != "" ->
        {:ok, metric, TimelessStack.UIDataSource.element_labels(element)}

      _ ->
        {:error, :element_selects_no_metric}
    end
  end

  # A rule belongs to an element when it watches the same metric and its
  # labels are not narrower than the element's. Equality would hide a rule
  # created before a label was added to the element.
  defp matches?(rule, metric, labels) do
    rule.metric == metric and
      Enum.all?(labels, fn {key, value} -> Map.get(rule.labels, key) == value end)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value

  # The rules database is a supervised process that may not be running --
  # alerting can be disabled, and the library raises rather than returning
  # errors. The canvas renders a message either way; it must not crash the
  # LiveView because alerting is off.
  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, {:alerting_unavailable, reason}}
  end

  defp db do
    config = Application.get_env(:timeless_stack, :alerting, [])
    store = Keyword.get(config, :store, :timeless_metrics)
    :"#{store}_db"
  end
end
