defmodule TimelessStack.Health do
  @moduledoc """
  Runtime health check for BEAM tuning verification.

  Call `TimelessStack.Health.check()` from a remote console or
  `TimelessStack.Health.report()` for a formatted printout.
  """

  def check do
    cores = :erlang.system_info(:logical_processors)
    schedulers = :erlang.system_info(:schedulers)
    schedulers_online = :erlang.system_info(:schedulers_online)
    dirty_cpu = :erlang.system_info(:dirty_cpu_schedulers)
    dirty_cpu_online = :erlang.system_info(:dirty_cpu_schedulers_online)
    bind_type = :erlang.system_info(:scheduler_bind_type)
    otp_release = :erlang.system_info(:otp_release) |> List.to_string()
    word_size = :erlang.system_info(:wordsize) * 8
    process_count = :erlang.system_info(:process_count)
    process_limit = :erlang.system_info(:process_limit)
    port_count = :erlang.system_info(:port_count)
    port_limit = :erlang.system_info(:port_limit)
    async_threads = :erlang.system_info(:thread_pool_size)

    # Memory
    mem = :erlang.memory()
    total_mb = div(mem[:total], 1_048_576)
    process_mb = div(mem[:processes], 1_048_576)
    ets_mb = div(mem[:ets], 1_048_576)
    binary_mb = div(mem[:binary], 1_048_576)

    # Run queue (should be low under normal operation)
    run_queue = :erlang.statistics(:run_queue)

    # Recon fragmentation (if available)
    fragmentation = recon_fragmentation()

    %{
      otp_release: otp_release,
      word_size: word_size,
      cores: cores,
      schedulers: schedulers,
      schedulers_online: schedulers_online,
      dirty_cpu_schedulers: dirty_cpu,
      dirty_cpu_online: dirty_cpu_online,
      scheduler_bind_type: bind_type,
      async_threads: async_threads,
      process_count: process_count,
      process_limit: process_limit,
      port_count: port_count,
      port_limit: port_limit,
      memory_total_mb: total_mb,
      memory_processes_mb: process_mb,
      memory_ets_mb: ets_mb,
      memory_binary_mb: binary_mb,
      run_queue: run_queue,
      fragmentation: fragmentation
    }
  end

  def report do
    data = check()

    bind_status =
      case data.scheduler_bind_type do
        :unbound -> "WARNING: NOT BOUND"
        type -> "OK (#{type})"
      end

    dirty_status =
      if data.dirty_cpu_schedulers >= data.cores,
        do: "OK (1:1)",
        else: "WARNING: #{data.dirty_cpu_schedulers} < #{data.cores} cores"

    lines = [
      "=== Timeless Health Check ===",
      "OTP:                   #{data.otp_release} (#{data.word_size}-bit)",
      "Cores:                 #{data.cores}",
      "Schedulers:            #{data.schedulers_online}/#{data.schedulers}",
      "Dirty CPU Schedulers:  #{data.dirty_cpu_online}/#{data.dirty_cpu_schedulers} — #{dirty_status}",
      "Scheduler Binding:     #{data.scheduler_bind_type} — #{bind_status}",
      "Async Threads:         #{data.async_threads}",
      "Processes:             #{data.process_count}/#{data.process_limit}",
      "Ports:                 #{data.port_count}/#{data.port_limit}",
      "Run Queue:             #{data.run_queue}#{if data.run_queue > data.cores, do: " — WARNING: higher than core count", else: ""}",
      "--- Memory ---",
      "Total:                 #{data.memory_total_mb} MB",
      "Processes:             #{data.memory_processes_mb} MB",
      "ETS:                   #{data.memory_ets_mb} MB",
      "Binary:                #{data.memory_binary_mb} MB",
      format_fragmentation(data.fragmentation),
      "============================="
    ]

    Enum.join(lines, "\n") |> IO.puts()
  end

  defp recon_fragmentation do
    if Code.ensure_loaded?(:recon_alloc) do
      try do
        :recon_alloc.fragmentation(:current)
        |> Enum.sort_by(fn {_alloc, props} -> Keyword.get(props, :mbcs_usage, 1.0) end)
        |> Enum.take(3)
      rescue
        _ -> :unavailable
      end
    else
      :not_loaded
    end
  end

  defp format_fragmentation(:not_loaded), do: "Fragmentation:         recon not loaded"
  defp format_fragmentation(:unavailable), do: "Fragmentation:         unavailable"

  defp format_fragmentation(frags) when is_list(frags) do
    lines =
      Enum.map(frags, fn {alloc, props} ->
        usage = Keyword.get(props, :mbcs_usage, 0.0)
        pct = Float.round(usage * 100, 1)
        "  #{alloc}: #{pct}% utilized"
      end)

    "--- Fragmentation (worst 3) ---\n" <> Enum.join(lines, "\n")
  end
end
