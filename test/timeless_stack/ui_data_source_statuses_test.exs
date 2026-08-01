defmodule TimelessStack.UIDataSourceStatusesTest do
  use ExUnit.Case, async: false

  alias TimelessStack.UIDataSource

  # Batched statuses run in the caller process, so the fake can use the
  # process dictionary for stubs and message passing for call counting.
  defmodule FakeLogs do
    def field_values(field, filters) do
      send(self(), {:field_values, field, filters})
      level = Keyword.fetch!(filters, :level)
      hosts = Process.get({:fake_hosts, level}, [])
      {:ok, Enum.map(hosts, &%{"value" => &1, "hits" => 1})}
    end

    def query(filters) do
      send(self(), {:query, filters})
      level = Keyword.fetch!(filters, :level)
      host = get_in(Keyword.fetch!(filters, :metadata), ["host"])

      entries =
        if host in Process.get({:fake_hosts, level}, []), do: [%{message: "boom"}], else: []

      {:ok, %{entries: entries}}
    end
  end

  setup do
    Application.put_env(:timeless_stack, :timeless_logs_module, FakeLogs)
    on_exit(fn -> Application.delete_env(:timeless_stack, :timeless_logs_module) end)

    {:ok, state} = UIDataSource.init(%{metrics_store: :unused_store})
    %{state: state}
  end

  defp element(id, type, meta) do
    %TimelessCanvas.Canvas.Element{
      id: id,
      type: type,
      label: id,
      x: 0.0,
      y: 0.0,
      width: 120.0,
      height: 100.0,
      meta: meta
    }
  end

  describe "statuses/2" do
    test "maps error/warning/ok per host and :unknown for hostless elements", %{state: state} do
      Process.put({:fake_hosts, :error}, ["bad-1"])
      Process.put({:fake_hosts, :warning}, ["warn-1"])

      elements = [
        element("e1", :server, %{"host" => "bad-1"}),
        element("e2", :server, %{"host" => "warn-1"}),
        element("e3", :server, %{"host" => "fine-1"}),
        element("e4", :server, %{})
      ]

      assert UIDataSource.statuses(state, elements) == %{
               "e1" => :error,
               "e2" => :warning,
               "e3" => :ok,
               "e4" => :unknown
             }
    end

    test "dedupes hosts: one grouped query per level regardless of element count",
         %{state: state} do
      elements =
        for n <- 1..5 do
          element("e#{n}", :server, %{"host" => "web-#{rem(n, 2)}"})
        end

      UIDataSource.statuses(state, elements)

      assert_received {:field_values, "host", error_filters}
      assert_received {:field_values, "host", warning_filters}
      refute_received {:field_values, _, _}
      refute_received {:query, _}

      assert Keyword.fetch!(error_filters, :level) == :error
      assert Keyword.fetch!(warning_filters, :level) == :warning
      assert is_integer(Keyword.fetch!(error_filters, :since))
      refute Keyword.has_key?(error_filters, :until)
    end

    test "non-status element types stay :unknown and trigger no queries", %{state: state} do
      elements = [
        element("g1", :graph, %{"host" => "web-1"}),
        element("t1", :text, %{"host" => "web-1"})
      ]

      assert UIDataSource.statuses(state, elements) == %{"g1" => :unknown, "t1" => :unknown}
      refute_received {:field_values, _, _}
    end

    test "empty element list issues no queries", %{state: state} do
      assert UIDataSource.statuses(state, []) == %{}
      refute_received {:field_values, _, _}
    end
  end

  describe "statuses_at/3" do
    test "bounds the window with :until and includes graph hosts", %{state: state} do
      Process.put({:fake_hosts, :error}, ["web-1"])
      time = DateTime.utc_now()

      elements = [
        element("g1", :graph, %{"host" => "web-1"}),
        element("s1", :server, %{"host" => "web-2"})
      ]

      assert UIDataSource.statuses_at(state, elements, time) == %{
               "g1" => :error,
               "s1" => :ok
             }

      assert_received {:field_values, "host", filters}

      assert Keyword.fetch!(filters, :until) == DateTime.to_unix(time)
      assert Keyword.fetch!(filters, :since) == DateTime.to_unix(time) - 60
    end
  end

  describe "parity with per-element status" do
    test "batch and single status agree for one element", %{state: state} do
      Process.put({:fake_hosts, :error}, ["bad-1"])
      Process.put({:fake_hosts, :warning}, ["warn-1"])

      for {host, expected} <- [{"bad-1", :error}, {"warn-1", :warning}, {"fine-1", :ok}] do
        el = element("single", :server, %{"host" => host})
        assert UIDataSource.status(state, el) == expected
        assert UIDataSource.statuses(state, [el]) == %{"single" => expected}
      end
    end
  end
end
