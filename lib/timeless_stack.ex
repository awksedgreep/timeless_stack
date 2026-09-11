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
  def backup(target_dir, opts \\ []) when is_binary(target_dir) and is_list(opts) do
    if data_plane_mode() == :rust do
      TimelessStack.Backup.create(target_dir, opts)
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
    operations =
      if data_plane_mode() == :rust do
        [
          metrics: fn -> TimelessStack.MetricsDataPlane.info(:timeless_metrics) end,
          logs: fn -> unwrap(TimelessStack.LogsDataPlane.stats()) end,
          traces: fn -> unwrap(TimelessStack.TracesDataPlane.stats()) end
        ]
      else
        [
          metrics: fn -> TimelessMetrics.info(:timeless_metrics) end,
          logs: fn -> TimelessLogs.stats() end,
          traces: fn -> TimelessTraces.stats() end
        ]
      end

    fan_out(operations, fn reason -> %{error: reason} end)
  end

  @doc """
  Flushes all three services' buffers to disk.
  """
  def flush do
    operations =
      if data_plane_mode() == :rust do
        [
          metrics: fn -> TimelessStack.MetricsDataPlane.flush(:timeless_metrics) end,
          logs: fn -> TimelessStack.LogsDataPlane.flush() end,
          traces: fn -> TimelessStack.TracesDataPlane.flush() end
        ]
      else
        [
          metrics: fn -> TimelessMetrics.flush(:timeless_metrics) end,
          logs: fn -> TimelessLogs.flush() end,
          traces: fn -> TimelessTraces.flush() end
        ]
      end

    results = fan_out(operations, &{:error, &1})

    failures = Map.reject(results, fn {_signal, result} -> success?(result) end)
    if map_size(failures) == 0, do: :ok, else: {:error, failures}
  end

  defp data_plane_mode, do: Application.get_env(:timeless_stack, :data_plane_mode, :rust)
  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: %{error: reason}
  defp success?(:ok), do: true
  defp success?({:ok, _result}), do: true
  defp success?(_result), do: false

  defp fan_out(operations, on_failure) do
    timeout = Application.get_env(:timeless_stack, :signal_fanout_timeout, 35_000)

    results =
      Task.async_stream(
        operations,
        fn {signal, operation} -> {signal, safely_call(operation)} end,
        max_concurrency: length(operations),
        ordered: true,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    operations
    |> Enum.zip(results)
    |> Map.new(fn
      {{signal, _operation}, {:ok, {signal, {:ok, result}}}} ->
        {signal, result}

      {{signal, _operation}, {:ok, {signal, {:error, reason}}}} ->
        {signal, on_failure.(reason)}

      {{signal, _operation}, {:exit, reason}} ->
        {signal, on_failure.({:signal_call_failed, reason})}
    end)
  end

  defp safely_call(operation) do
    {:ok, operation.()}
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
