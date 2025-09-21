defmodule Twine.Internal.CallTrackerTest do
  alias Twine.Internal.CallTracker

  use ExUnit.Case

  test "returns event details after call, return_from, and return_to" do
    {:ok, tracker} = CallTracker.start_link()
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
      )

    assert res == {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :return_from, {MyModule, :my_function, 2}, :ok}
      )

    assert res == {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :return_to, {MyModule, :my_parent_function, 0}}
      )

    expected_ready_payload =
      {
        pid,
        {MyModule, :my_function, [:foo, :bar]},
        %{:return_from => :ok, :return_to => {MyModule, :my_parent_function, 0}}
      }

    assert res ==
             {:ok, %CallTracker.Result{status: {:ready, expected_ready_payload}, warnings: []}}
  end

  test "returns event details after call, exception_from, and return_to" do
    {:ok, tracker} = CallTracker.start_link()
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
      )

    assert res == {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :exception_from, {MyModule, :my_function, 2}, :badarg}
      )

    assert res == {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :return_to, {MyModule, :my_parent_function, 0}}
      )

    expected_ready_payload =
      {
        pid,
        {MyModule, :my_function, [:foo, :bar]},
        %{:exception_from => :badarg, :return_to => {MyModule, :my_parent_function, 0}}
      }

    assert res ==
             {:ok, %CallTracker.Result{status: {:ready, expected_ready_payload}, warnings: []}}
  end

  test "returns warning when overwriting an existing call" do
    {:ok, tracker} = CallTracker.start_link()
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    {:ok, %CallTracker.Result{status: :not_ready, warnings: []}} =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
      )

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :call, {MyModule, :my_function, [:wibble, :wobble]}}
      )

    assert res ==
             {:ok,
              %CallTracker.Result{
                status: :not_ready,
                warnings: [{:overwrote_call, {MyModule, :my_function, [:foo, :bar]}}]
              }}
  end
end
