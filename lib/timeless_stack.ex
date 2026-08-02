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
  Requests a coordinated telemetry backup.

  Session 6 supplies the drain/checkpoint/manifest workflow. Rust mode refuses
  the old direct-owner backup calls so Phoenix can never open a telemetry
  database behind the Rust process.
  """
  def backup(target_dir) when is_binary(target_dir) do
    if data_plane_mode() == :rust do
      {:error, {:unsupported_capability, :coordinated_backup_pending_session_6}}
    else
      embedded_backup(target_dir)
    end
  end

  defp embedded_backup(target_dir) do
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
    if data_plane_mode() == :rust do
      %{
        metrics: TimelessStack.MetricsDataPlane.info(:timeless_metrics),
        logs: unwrap(TimelessStack.LogsDataPlane.stats()),
        traces: unwrap(TimelessStack.TracesDataPlane.stats())
      }
    else
      %{
        metrics: TimelessMetrics.info(:timeless_metrics),
        logs: TimelessLogs.stats(),
        traces: TimelessTraces.stats()
      }
    end
  end

  @doc """
  Flushes all three services' buffers to disk.
  """
  def flush do
    results =
      if data_plane_mode() == :rust do
        %{
          metrics: TimelessStack.MetricsDataPlane.flush(:timeless_metrics),
          logs: TimelessStack.LogsDataPlane.flush(),
          traces: TimelessStack.TracesDataPlane.flush()
        }
      else
        %{
          metrics: TimelessMetrics.flush(:timeless_metrics),
          logs: TimelessLogs.flush(),
          traces: TimelessTraces.flush()
        }
      end

    failures = Map.reject(results, fn {_signal, result} -> success?(result) end)
    if map_size(failures) == 0, do: :ok, else: {:error, failures}
  end

  defp data_plane_mode, do: Application.get_env(:timeless_stack, :data_plane_mode, :rust)
  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: %{error: reason}
  defp success?(:ok), do: true
  defp success?({:ok, _result}), do: true
  defp success?(_result), do: false
end
