defmodule TimelessStackTest do
  use ExUnit.Case

  test "version returns project version" do
    assert is_binary(TimelessStack.version())
  end
end
