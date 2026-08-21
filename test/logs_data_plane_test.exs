defmodule TimelessStack.LogsDataPlaneTest do
  @moduledoc """
  Canvas filters become one LogsQL expression evaluated by the data plane.

  Getting this wrong fails silently: the tail returns 200 and streams nothing,
  which is indistinguishable from a quiet system.
  """
  use ExUnit.Case, async: true

  alias TimelessStack.LogsDataPlane

  describe "logsql_query/1" do
    test "no filters means everything" do
      # An element whose host has been cleared is asking for all logs, not none.
      assert LogsDataPlane.logsql_query([]) == "*"
      assert LogsDataPlane.logsql_query(metadata: %{}) == "*"
    end

    test "a host filter becomes a quoted field match" do
      assert LogsDataPlane.logsql_query(metadata: %{"host" => "srv1178013"}) ==
               ~s(host:"srv1178013")
    end

    test "hostnames with dots and dashes stay quoted" do
      # The reason quoting is unconditional: a bare token with dots either fails
      # to parse or matches something other than intended.
      assert LogsDataPlane.logsql_query(metadata: %{"host" => "web-1.example.com"}) ==
               ~s(host:"web-1.example.com")
    end

    test "level is included alongside metadata" do
      query = LogsDataPlane.logsql_query(metadata: %{"host" => "web-1"}, level: :error)

      assert query =~ ~s(host:"web-1")
      assert query =~ ~s(level:"error")
      assert query =~ " AND "
    end

    test "level alone works" do
      assert LogsDataPlane.logsql_query(level: :warning) == ~s(level:"warning")
    end

    test "several metadata fields are all applied" do
      query = LogsDataPlane.logsql_query(metadata: %{"host" => "web-1", "service" => "api"})

      assert query =~ ~s(host:"web-1")
      assert query =~ ~s(service:"api")
      assert query =~ " AND "
    end

    test "quotes in a value are escaped rather than ending the term" do
      # Otherwise a crafted value would change the shape of the query.
      assert LogsDataPlane.logsql_query(metadata: %{"host" => ~s(a"b)}) ==
               ~s(host:"a\\"b")
    end
  end
end
