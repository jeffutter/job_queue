defmodule JobQueueTest do
  use ExUnit.Case
  doctest JobQueue

  test "greets the world" do
    assert JobQueue.hello() == :world
  end
end
