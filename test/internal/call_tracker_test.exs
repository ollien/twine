defmodule Twine.Internal.CallTrackerTest do
  alias Twine.Internal.CallTracker

  use ExUnit.Case

  test "returns event details after call, return_from, and return_to" do
    {:ok, tracker} = CallTracker.start_link(&flunk/1)
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
    {:ok, tracker} = CallTracker.start_link(&flunk/1)
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

  test "returns event details after call, exception_from, and DOWN" do
    {:ok, tracker} =
      CallTracker.start_link(&flunk/1)

    pid =
      spawn(fn ->
        :erlang.error("test error")
      end)

    # Ensure we get the DOWN, so we know the process is actually dead.
    # Otherwise, there is a race between the next two clauses and the DOWN.
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

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

    assert {:ok, %CallTracker.Result{status: {:ready, ready_payload}, warnings: []}} = res

    assert {
             ^pid,
             {MyModule, :my_function, [:foo, :bar]},
             %{
               # Normally we could expect to get a more intelligent DOWN reason, but because 
               # we've set up the test for the process to crash before we begin asserting, we will always get noproc
               :DOWN => :noproc,
               :exception_from => :badarg
             }
           } = ready_payload
  end

  test "calls callback with event details after call, exception_from, and DOWN" do
    me = self()

    {:ok, tracker} =
      CallTracker.start_link(fn result ->
        send(me, result)
      end)

    pid =
      spawn(fn ->
        receive do
          _anything -> :erlang.error("test error")
        end
      end)

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

    send(pid, :die)
    assert_receive {:ok, %CallTracker.Result{status: {:ready, ready_payload}, warnings: []}}

    assert {
             ^pid,
             {MyModule, :my_function, [:foo, :bar]},
             %{
               :DOWN => {"test error", _stacktrace},
               :exception_from => :badarg
             }
           } = ready_payload
  end

  test "returns warning when overwriting an existing call" do
    {:ok, tracker} = CallTracker.start_link(&flunk/1)
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
                warnings: [{:overwrote_call, pid, {MyModule, :my_function, [:foo, :bar]}}]
              }}
  end

  test "does not warn when getting two calls on different pids" do
    {:ok, tracker} = CallTracker.start_link(&flunk/1)
    pid1 = :erlang.list_to_pid(~c"<0.1.0>")
    pid2 = :erlang.list_to_pid(~c"<0.2.0>")

    {:ok, %CallTracker.Result{status: :not_ready, warnings: []}} =
      CallTracker.handle_event(
        tracker,
        {:trace, pid1, :call, {MyModule, :my_function, [:foo, :bar]}}
      )

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid2, :call, {MyModule, :my_function, [:wibble, :wobble]}}
      )

    assert res ==
             {:ok,
              %CallTracker.Result{
                status: :not_ready,
                warnings: []
              }}
  end

  test "returns error when getting a non-call event for the wrong MFA" do
    {:ok, tracker} = CallTracker.start_link(&flunk/1)
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    {:ok, %CallTracker.Result{status: :not_ready, warnings: []}} =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
      )

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :return_from, {MyModule, :another_function, 5}, nil}
      )

    assert res == {:error, {:wrong_mfa, pid, {MyModule, :my_function, [:foo, :bar]}}}
  end

  test "returns missing when getting a non-call event for a different pid" do
    {:ok, tracker} = CallTracker.start_link(&flunk/1)
    pid1 = :erlang.list_to_pid(~c"<0.1.0>")
    pid2 = :erlang.list_to_pid(~c"<0.2.0>")

    {:ok, %CallTracker.Result{status: :not_ready, warnings: []}} =
      CallTracker.handle_event(
        tracker,
        {:trace, pid1, :call, {MyModule, :my_function, [:foo, :bar]}}
      )

    res =
      CallTracker.handle_event(
        tracker,
        {:trace, pid2, :return_from, {MyModule, :another_function, 5}, nil}
      )

    assert res == {:error, {:missing, pid2, {MyModule, :another_function, 5}}}
  end
end
