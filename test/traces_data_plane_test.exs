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
end
