defmodule TimelessStack.UIDataSourceSeriesTest do
  @moduledoc """
  A cold cache and a host with no metrics both answer with an empty list.

  Only the cache knows which one it is looking at, and the panel needs that
  answer to avoid telling a reader "no metrics" while a fetch is in flight.
  """
  use ExUnit.Case, async: true

  alias TimelessStack.UIDataSource

  setup do
    table = :"series_test_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :public, :set])
    %{state: %{cache_table: table}, table: table}
  end

  test "a host absent from the cache is not loaded yet", %{state: state} do
    refute UIDataSource.series_loaded?(state, "never-asked")
  end

  test "a host cached with no series is loaded", %{state: state, table: table} do
    # The distinction that matters: cached-and-empty is a real answer.
    :ets.insert(table, {{:host_series, "quiet"}, [], 0})

    assert UIDataSource.series_loaded?(state, "quiet")
  end

  test "a host cached with series is loaded", %{state: state, table: table} do
    :ets.insert(table, {{:host_series, "busy"}, [{"cpu", %{}}], 0})

    assert UIDataSource.series_loaded?(state, "busy")
  end

  test "a missing cache table reports not loaded rather than crashing", %{state: state} do
    assert UIDataSource.series_loaded?(%{state | cache_table: :no_such_table}, "any") == false
  end
end
