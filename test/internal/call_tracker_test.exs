defmodule Twine.Internal.CallTrackerTest do
  alias Twine.Internal.CallTracker

  use ExUnit.Case

  test "popping a call immediately returns nil" do
    {:ok, tracker} = CallTracker.start_link()
    pid = :erlang.list_to_pid(~c"<0.1.0>")
    res = CallTracker.pop_call(tracker, pid, {MyModule, :my_function, 2})

    assert res == nil
  end

  test "popping a call after being tracked returns the original mfa" do
    {:ok, tracker} = CallTracker.start_link()
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    CallTracker.log_call(tracker, pid, {MyModule, :my_function, [:foo, :bar]})
    res = CallTracker.pop_call(tracker, pid, {MyModule, :my_function, 2})

    assert res == {MyModule, :my_function, [:foo, :bar]}
  end

  test "popping a call twice returns nil" do
    {:ok, tracker} = CallTracker.start_link()
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    CallTracker.log_call(tracker, pid, {MyModule, :my_function, [:foo, :bar]})
    CallTracker.pop_call(tracker, pid, {MyModule, :my_function, 2})
    res = CallTracker.pop_call(tracker, pid, {MyModule, :my_function, 2})

    assert res == nil
  end
end
