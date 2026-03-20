defmodule CurrentTest do
  use ExUnit.Case
  doctest Current

  test "greets the world" do
    assert Current.hello() == :world
  end
end
