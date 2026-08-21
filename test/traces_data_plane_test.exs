defmodule TimelessStack.TracesDataPlaneTest do
  @moduledoc """
  Canvas trace-element options become data plane tail filters.

  Getting this wrong fails silently: the tail returns 200 and streams
  nothing, which is indistinguishable from a system producing no spans.
  """
  use ExUnit.Case, async: true

  alias TimelessStack.TracesDataPlane

  describe "tail_filters/1" do
    test "no options means every span" do
      # A trace element with its fields cleared is asking for everything.
      assert TracesDataPlane.tail_filters([]) == []
    end

    test "the canvas's own filter keys pass through" do
      opts = [service: "checkout", name: "GET /orders", kind: :server]
      assert TracesDataPlane.tail_filters(opts) == opts
    end

    test "a host becomes an attribute filter" do
      # build_trace_opts/1 turns an element's host field into this shape.
      opts = [attributes: %{"host.name" => "srv1178013"}]
      assert TracesDataPlane.tail_filters(opts) == opts
    end

    test "options the tail cannot express are dropped rather than sent" do
      # The stream manager may pass bookkeeping the data plane would reject
      # outright, which would leave the element with no subscription at all.
      assert TracesDataPlane.tail_filters(service: "checkout", element_id: "abc") ==
               [service: "checkout"]
    end
  end

  defmodule StubClient do
    @moduledoc false
    def search(filters) do
      send(self(), {:search, filters})

      entries = [
        %{name: "on our host", attributes: %{"host.name" => "srv-a", "http.status_code" => 500}},
        %{name: "on other host", attributes: %{"host.name" => "srv-b"}},
        %{name: "no attributes", attributes: %{}}
      ]

      {:ok, %{entries: entries, total: 3, limit: 100, offset: 0, has_more: false}}
    end
  end

  describe "query/1" do
    setup do
      Application.put_env(:timeless_stack, :traces_data_plane_client, StubClient)
      on_exit(fn -> Application.delete_env(:timeless_stack, :traces_data_plane_client) end)
    end

    test "the timeline's filters reach the search endpoint" do
      assert {:ok, _} = TracesDataPlane.query(service: "checkout", limit: 50, order: :desc)

      assert_received {:search, filters}
      assert filters[:service] == "checkout"
      assert filters[:order] == :desc
    end

    test "an attribute filter selects only matching spans" do
      # The search endpoint has no attribute predicate, so this is applied
      # after the fact -- but the caller must not be able to tell.
      assert {:ok, %{entries: entries}} =
               TracesDataPlane.query(attributes: %{"host.name" => "srv-a"}, limit: 50)

      assert Enum.map(entries, & &1.name) == ["on our host"]
    end

    test "an attribute filter widens the page it asks for" do
      # Filtering a 50-span page down would quietly return far fewer than the
      # window asked for.
      assert {:ok, _} = TracesDataPlane.query(attributes: %{"host.name" => "srv-a"}, limit: 50)

      assert_received {:search, filters}
      assert filters[:limit] == 100
    end

    test "attribute values compare as text, as the tail's do" do
      assert {:ok, %{entries: [entry]}} =
               TracesDataPlane.query(attributes: %{"http.status_code" => "500"}, limit: 50)

      assert entry.name == "on our host"
    end

    test "the requested limit is still honoured after filtering" do
      assert {:ok, %{entries: entries}} = TracesDataPlane.query(limit: 2)
      assert length(entries) == 2
    end

    test "attributes are never sent to an endpoint that would reject them" do
      assert {:ok, _} = TracesDataPlane.query(attributes: %{"host.name" => "srv-a"})

      assert_received {:search, filters}
      refute Keyword.has_key?(filters, :attributes)
    end
  end
end
