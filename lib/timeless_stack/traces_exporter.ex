defmodule TimelessStack.TracesExporter do
  @moduledoc """
  OpenTelemetry exporter that preserves the SDK's full OTLP representation and
  sends one protobuf batch to the Rust traces process.
  """

  @behaviour :otel_exporter_traces

  alias TimelessUI.TracesDataPlane.Client

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
        opts = Map.get(state, :client_opts, [])

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
