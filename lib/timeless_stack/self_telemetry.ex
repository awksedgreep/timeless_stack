defmodule TimelessStack.SelfTelemetry do
  @moduledoc """
  Stores the data planes' own `/metrics` in the metrics plane.

  Each plane reports counters and histograms about itself (write retries,
  read waits, maintenance step and flush timings), and a counter that is
  only ever read as its current value has no history: nobody can say when
  the retries happened or what else was going on. Every interval this
  process reads `/metrics` from the metrics, logs and traces planes and
  writes the text to the metrics plane through its Prometheus import, so
  those families are queryable like any other series.

  This is deliberately the stack's job rather than the engine's. The
  planes stay unaware that anything keeps their counters, and an embedded
  user of the engine gets no collection they did not ask for; the cost is
  one extra loopback round trip per plane per interval.

  Family names already carry their plane (`timeless_metrics_`,
  `timeless_logs_`, `timeless_traces_`), so nothing is relabelled. Samples
  carry no timestamp and are stamped by the import on arrival.
  """

  use GenServer

  require Logger

  @default_interval :timer.seconds(30)
  @request_timeout 5_000
  # A plane's exposition is a few tens of kilobytes; this only stops a
  # response that is not one from being held in memory and re-posted.
  @max_body_bytes 4 * 1024 * 1024

  @sources [
    metrics: TimelessUI.MetricsDataPlane.Process,
    logs: TimelessUI.LogsDataPlane.Process,
    traces: TimelessUI.TracesDataPlane.Process
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Collect once now and return what happened to each plane."
  def collect(server \\ __MODULE__), do: GenServer.call(server, :collect, 30_000)

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, @default_interval),
      sources: Keyword.get(opts, :sources, @sources),
      request: Keyword.get(opts, :request, &Req.request/1),
      writer: Keyword.get(opts, :writer, TimelessUI.MetricsDataPlane.Client),
      # What each plane's last collection came to, so a plane that stays
      # down is logged when it goes down and when it returns, not every
      # interval in between.
      last: %{}
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:collect, _from, state) do
    {results, state} = collect_all(state)
    {:reply, results, state}
  end

  @impl true
  def handle_info(:collect, state) do
    {_results, state} = collect_all(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(%{interval: interval}) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :collect, interval)

  # No interval: collects only when asked, which is how the tests drive it.
  defp schedule(_state), do: :ok

  defp collect_all(state) do
    results =
      Map.new(state.sources, fn {signal, process} -> {signal, collect_one(process, state)} end)

    Enum.each(results, fn {signal, result} -> report(signal, result, state.last[signal]) end)

    {results,
     %{state | last: Map.new(results, fn {signal, result} -> {signal, outcome(result)} end)}}
  end

  # A plane's owner is registered under its module's name; a `{module, server}`
  # pair names one registered otherwise.
  defp collect_one(process, state) when is_atom(process),
    do: collect_one({process, process}, state)

  defp collect_one({module, server}, state) do
    with {:ok, endpoint} <- module.await_ready(server, @request_timeout),
         {:ok, header} <- module.authorization_header(server),
         {:ok, body} <- fetch(endpoint, header, state.request),
         :ok <- state.writer.import_prometheus(body, timeout: @request_timeout) do
      :ok
    else
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  rescue
    error -> {:error, {:raised, error}}
  catch
    # A plane that is still starting, or gone, answers a call with an exit.
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp fetch(endpoint, header, request) do
    options = [
      method: :get,
      url: endpoint <> "/metrics",
      headers: List.wrap(header),
      receive_timeout: @request_timeout,
      retry: false,
      decode_body: false
    ]

    case request.(options) do
      {:ok, %{status: 200, body: body}}
      when is_binary(body) and byte_size(body) > @max_body_bytes ->
        {:error, {:body_too_large, byte_size(body)}}

      {:ok, %{status: 200, body: body}} when is_binary(body) and body != "" ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, :empty_body}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp outcome(:ok), do: :ok
  defp outcome({:error, _reason}), do: :error

  defp report(signal, {:error, reason}, previous) when previous != :error do
    Logger.warning("self telemetry: #{signal} plane not collected: #{inspect(reason)}")
  end

  defp report(signal, :ok, :error) do
    Logger.info("self telemetry: #{signal} plane collected again")
  end

  defp report(_signal, _result, _previous), do: :ok
end
