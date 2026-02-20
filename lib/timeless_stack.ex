defmodule TimelessStack do
  @moduledoc """
  Unified API for the Timeless observability stack.

  Composes TimelessMetrics, TimelessLogs, and TimelessTraces into a single
  standalone BEAM application with sensible defaults for container deployment.
  """

  @version Mix.Project.config()[:version]

  @doc """
  Returns the stack version.
  """
  def version, do: @version

  @doc """
  Backs up all three databases into subdirectories of `target_dir`.

  Creates the following layout:
      target_dir/
        metrics/
        logs/
        traces/
  """
  def backup(target_dir) do
    metrics_dir = Path.join(target_dir, "metrics")
    logs_dir = Path.join(target_dir, "logs")
    traces_dir = Path.join(target_dir, "traces")

    for dir <- [metrics_dir, logs_dir, traces_dir] do
      File.mkdir_p!(dir)
    end

    results = %{
      metrics: TimelessMetrics.backup(:timeless_metrics, metrics_dir),
      logs: TimelessLogs.backup(logs_dir),
      traces: TimelessTraces.backup(traces_dir)
    }

    errors =
      results
      |> Enum.filter(fn {_k, v} -> match?({:error, _}, v) end)
      |> Enum.into(%{})

    if map_size(errors) == 0 do
      {:ok, Map.new(results, fn {k, {:ok, v}} -> {k, v} end)}
    else
      {:error, errors}
    end
  end

  @doc """
  Returns aggregated info/stats from all three services.
  """
  def info do
    %{
      metrics: TimelessMetrics.info(:timeless_metrics),
      logs: TimelessLogs.stats(),
      traces: TimelessTraces.stats()
    }
  end

  @doc """
  Flushes all three services' buffers to disk.
  """
  def flush do
    TimelessMetrics.flush(:timeless_metrics)
    TimelessLogs.flush()
    TimelessTraces.flush()
    :ok
  end
end
