defmodule TwineTest do
  use ExUnit.Case
  doctest Twine

  test "greets the world" do
    assert Twine.hello() == :world
  end
end
