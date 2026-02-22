defmodule TimelessStack.BeamMetrics do
  @moduledoc """
  Bridges BEAM VM telemetry events into TimelessMetrics.

  Attaches to the `:telemetry_poller` events emitted by
  TimelessUIWeb.Telemetry and writes them as time series.

  ## Metrics collected

  - `vm_memory_total` — total BEAM memory (bytes)
  - `vm_memory_processes` — memory used by processes (bytes)
  - `vm_memory_ets` — memory used by ETS tables (bytes)
  - `vm_memory_binary` — memory used by binaries (bytes)
  - `vm_memory_atom` — memory used by atoms (bytes)
  - `vm_total_run_queue_lengths_total` — total run queue length
  - `vm_total_run_queue_lengths_cpu` — CPU run queue length
  - `vm_total_run_queue_lengths_io` — IO run queue length
  """

  require Logger

  @store :timeless_metrics
  @labels %{}

  def attach do
    :telemetry.attach_many(
      "timeless-stack-beam-metrics",
      [
        [:vm, :memory],
        [:vm, :total_run_queue_lengths],
        [:vm, :system_counts]
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    Logger.info("BeamMetrics attached to VM telemetry events")
  end

  def handle_event([:vm, :memory], measurements, _metadata, _config) do
    ts = System.os_time(:second)

    for {key, value} <- measurements do
      TimelessMetrics.write(@store, "vm_memory_#{key}", @labels, value, timestamp: ts)
    end
  end

  def handle_event([:vm, :total_run_queue_lengths], measurements, _metadata, _config) do
    ts = System.os_time(:second)

    for {key, value} <- measurements do
      TimelessMetrics.write(@store, "vm_run_queue_#{key}", @labels, value, timestamp: ts)
    end
  end

  def handle_event([:vm, :system_counts], measurements, _metadata, _config) do
    ts = System.os_time(:second)

    for {key, value} <- measurements do
      TimelessMetrics.write(@store, "vm_#{key}", @labels, value, timestamp: ts)
    end
  end
end
