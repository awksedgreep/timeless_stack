defmodule TimelessStack.TracesExporter do
  @moduledoc """
  OpenTelemetry exporter that preserves the SDK's full OTLP representation and
  sends one protobuf batch to the Rust traces process.

  Encoding and HTTP work run in OpenTelemetry's batch-processor runner, never
  in an instrumented request process. The application pins that processor to a
  2,048-span queue, a five-second batch interval, and a ten-second export
  deadline. A slow data plane therefore causes a bounded batch drop; it cannot
  grow an unbounded queue or apply backpressure to request handling.
  """

  @behaviour :otel_exporter_traces

  alias TimelessUI.TracesDataPlane.Client

  @default_timeout 8_000

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def export(tab, resource, state) do
    case :otel_otlp_traces.to_proto(tab, resource) do
      :empty ->
        :ok

      request ->
        body =
          :opentelemetry_exporter_trace_service_pb.encode_msg(
            request,
            :export_trace_service_request
          )

        client = Map.get(state, :client, Client)
        opts = state |> Map.get(:client_opts, []) |> Keyword.put_new(:timeout, @default_timeout)

        case client.ingest_otlp(body, Keyword.put(opts, :format, :protobuf)) do
          {:ok, _response} -> :ok
          {:error, _reason} -> :failed_retryable
        end
    end
  rescue
    _error -> :failed_not_retryable
  end

  @impl true
  def shutdown(_state), do: :ok
end
