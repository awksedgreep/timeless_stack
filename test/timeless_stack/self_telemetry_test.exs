defmodule TimelessStack.SelfTelemetryTest do
  @moduledoc """
  The planes' counters only have a history if something keeps reading them.
  These cover that every plane is read and written, and that one plane being
  down costs only that plane's samples.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TimelessStack.Application, as: App
  alias TimelessStack.SelfTelemetry

  defmodule Plane do
    # Stands in for a data plane's owner process: `await_ready/2` and
    # `authorization_header/1` are all the collector asks of one.
    def await_ready(:down_plane, _timeout), do: exit(:noproc)
    def await_ready(name, _timeout), do: {:ok, "http://127.0.0.1/#{name}"}

    def authorization_header(:open_plane), do: {:ok, nil}
    def authorization_header(_name), do: {:ok, {"authorization", "Bearer secret"}}
  end

  defmodule Writer do
    def import_prometheus(body, _opts) do
      send(Application.fetch_env!(:timeless_stack, :self_telemetry_test_pid), {:imported, body})
      # What the real client answers for the import's 204.
      :ok
    end
  end

  setup do
    Application.put_env(:timeless_stack, :self_telemetry_test_pid, self())
    original = Application.get_env(:timeless_stack, :self_telemetry)

    on_exit(fn ->
      Application.delete_env(:timeless_stack, :self_telemetry_test_pid)

      if original,
        do: Application.put_env(:timeless_stack, :self_telemetry, original),
        else: Application.delete_env(:timeless_stack, :self_telemetry)
    end)

    :ok
  end

  defp start(sources, request) do
    # Sources name the stand-in by atom; the collector calls the module in
    # the pair with that atom as the server.
    start_supervised!(
      {SelfTelemetry,
       name: :self_telemetry_under_test,
       interval: nil,
       sources: sources,
       request: request,
       writer: Writer}
    )
  end

  defp respond(test, responses) do
    fn options ->
      send(test, {:requested, options[:url], options[:headers]})
      Map.fetch!(responses, options[:url])
    end
  end

  test "every plane's exposition is written to the metrics plane" do
    test = self()

    request =
      respond(test, %{
        "http://127.0.0.1/metrics_plane/metrics" =>
          {:ok, %{status: 200, body: "timeless_metrics_a 1\n"}},
        "http://127.0.0.1/open_plane/metrics" =>
          {:ok, %{status: 200, body: "timeless_logs_b 2\n"}}
      })

    server = start([metrics: {Plane, :metrics_plane}, logs: {Plane, :open_plane}], request)

    assert SelfTelemetry.collect(server) == %{metrics: :ok, logs: :ok}
    assert_received {:imported, "timeless_metrics_a 1\n"}
    assert_received {:imported, "timeless_logs_b 2\n"}

    # The plane's own credential goes with the read, and an open plane gets none.
    assert_received {:requested, "http://127.0.0.1/metrics_plane/metrics",
                     [{"authorization", "Bearer secret"}]}

    assert_received {:requested, "http://127.0.0.1/open_plane/metrics", []}
  end

  test "a plane that is down costs only its own samples, and is logged once" do
    request =
      respond(self(), %{
        "http://127.0.0.1/metrics_plane/metrics" =>
          {:ok, %{status: 200, body: "timeless_metrics_a 1\n"}}
      })

    server = start([traces: {Plane, :down_plane}, metrics: {Plane, :metrics_plane}], request)

    log =
      capture_log(fn ->
        assert %{traces: {:error, {:exit, :noproc}}, metrics: :ok} = SelfTelemetry.collect(server)
        assert %{traces: {:error, _}, metrics: :ok} = SelfTelemetry.collect(server)
      end)

    assert length(String.split(log, "traces plane not collected")) == 2
    assert_received {:imported, "timeless_metrics_a 1\n"}
    assert_received {:imported, "timeless_metrics_a 1\n"}
  end

  test "a response that is not an exposition is not written" do
    request =
      respond(self(), %{
        "http://127.0.0.1/metrics_plane/metrics" => {:ok, %{status: 401, body: "no"}},
        "http://127.0.0.1/open_plane/metrics" => {:ok, %{status: 200, body: ""}}
      })

    server = start([metrics: {Plane, :metrics_plane}, logs: {Plane, :open_plane}], request)

    capture_log(fn ->
      assert SelfTelemetry.collect(server) == %{
               metrics: {:error, {:status, 401}},
               logs: {:error, :empty_body}
             }
    end)

    refute_received {:imported, _}
  end

  test "it is supervised only when enabled" do
    Application.delete_env(:timeless_stack, :self_telemetry)
    assert App.self_telemetry_children() == []

    Application.put_env(:timeless_stack, :self_telemetry, enabled: false, interval: 1_000)
    assert App.self_telemetry_children() == []

    Application.put_env(:timeless_stack, :self_telemetry, enabled: true, interval: 15_000)
    assert App.self_telemetry_children() == [{SelfTelemetry, interval: 15_000}]
  end
end
