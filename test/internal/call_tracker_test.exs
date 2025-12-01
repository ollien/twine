defmodule Twine.Internal.CallTrackerTest do
  alias Twine.Internal.CallTracker

  use ExUnit.Case, async: true

  def send_to(self_pid) do
    fn result ->
      send(self_pid, result)
    end
  end

  test "returns event details after call, return_from, and return_to" do
    {:ok, tracker} = CallTracker.start_link(send_to(self()))
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :return_from, {MyModule, :my_function, 2}, :ok}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

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

    assert_receive {:ok,
                    %CallTracker.Result{status: {:ready, ^expected_ready_payload}, warnings: []}},
                   250
  end

  test "returns event details after call, exception_from, and return_to" do
    {:ok, tracker} = CallTracker.start_link(send_to(self()))
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :exception_from, {MyModule, :my_function, 2}, :badarg}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

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

    assert_receive {:ok,
                    %CallTracker.Result{status: {:ready, ^expected_ready_payload}, warnings: []}},
                   250
  end

  test "returns event details after call, exception_from, and DOWN" do
    {:ok, tracker} = CallTracker.start_link(send_to(self()))

    pid =
      spawn(fn ->
        :erlang.error("test error")
      end)

    # Ensure we get the DOWN, so we know the process is actually dead.
    # Otherwise, there is a race between the next two clauses and the DOWN.
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :exception_from, {MyModule, :my_function, 2}, :badarg}
    )

    assert_receive {:ok, %CallTracker.Result{status: {:ready, ready_payload}, warnings: []}}, 250

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
    {:ok, tracker} = CallTracker.start_link(send_to(self()))

    pid =
      spawn(fn ->
        receive do
          _anything -> :erlang.error("test error")
        end
      end)

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :exception_from, {MyModule, :my_function, 2}, :badarg}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    send(pid, :die)
    assert_receive {:ok, %CallTracker.Result{status: {:ready, ready_payload}, warnings: []}}, 250

    assert {
             ^pid,
             {MyModule, :my_function, [:foo, :bar]},
             %{
               :DOWN => {"test error", _stacktrace},
               :exception_from => :badarg
             }
           } = ready_payload
  end

  test "does not warn when getting two calls on different pids" do
    {:ok, tracker} = CallTracker.start_link(send_to(self()))
    pid1 = :erlang.list_to_pid(~c"<0.1.0>")
    pid2 = :erlang.list_to_pid(~c"<0.2.0>")

    CallTracker.handle_event(
      tracker,
      {:trace, pid1, :call, {MyModule, :my_function, [:foo, :bar]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid2, :call, {MyModule, :my_function, [:wibble, :wobble]}}
    )

    assert_receive {:ok,
                    %CallTracker.Result{
                      status: :not_ready,
                      warnings: []
                    }},
                   250
  end

  test "returns error when getting a non-call event for the wrong MFA" do
    {:ok, tracker} = CallTracker.start_link(send_to(self()))
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :return_from, {MyModule, :another_function, 5}, nil}
    )

    assert_receive {:error,
                    {:wrong_mfa, ^pid, {MyModule, :my_function, [:foo, :bar]},
                     {:return_from, nil}}},
                   250
  end

  test "returns missing when getting a non-call event for a different pid" do
    {:ok, tracker} = CallTracker.start_link(send_to(self()))
    pid1 = :erlang.list_to_pid(~c"<0.1.0>")
    pid2 = :erlang.list_to_pid(~c"<0.2.0>")

    CallTracker.handle_event(
      tracker,
      {:trace, pid1, :call, {MyModule, :my_function, [:foo, :bar]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid2, :return_from, {MyModule, :another_function, 5}, nil}
    )

    assert_receive {:error,
                    {:missing, ^pid2, {MyModule, :another_function, 5}, {:return_from, nil}}},
                   250
  end

  test "process stops when tracer process stops" do
    {:ok, tracker} = CallTracker.start_link(&flunk/1, tracer_down_timeout: 0)
    Process.unlink(tracker)
    monitor_ref = Process.monitor(tracker)

    pid =
      spawn(fn ->
        receive do
          _anything -> :erlang.exit(:normal)
        end
      end)

    CallTracker.monitor_tracer(tracker, pid)
    send(pid, :die)

    assert_receive {:DOWN, ^monitor_ref, :process, ^tracker, _reason}
  end

  test "demonitors the original tracker if it's told to track twice" do
    {:ok, tracker} = CallTracker.start_link(send_to(self()), tracer_down_timeout: 10_000)

    pid1 =
      spawn(fn ->
        receive do
          _anything -> :erlang.exit(:normal)
        end
      end)

    pid2 =
      spawn(fn ->
        receive do
          _anything -> :erlang.exit(:normal)
        end
      end)

    CallTracker.monitor_tracer(tracker, pid1)
    CallTracker.monitor_tracer(tracker, pid2)
    # an incorrect implementation would be notified of this kill
    Process.exit(pid1, :kill)

    # Ensure we do not get a DOWN for the pid we just killed, it's not important to us anymore
    refute_receive {:error, {:missing, ^pid1, :unknown, {:DOWN, :killed}}}, 250
  end

  test "tracks returns in tail calls" do
    {:ok, tracker} = CallTracker.start_link(send_to(self()))
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    # Simulate a tail call by calling handle_event in succession
    call_args = [
      [:foo, :bar],
      [:baz, :whizbang],
      [:wibble, :wobble]
    ]

    Enum.each(call_args, fn args ->
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :call, {MyModule, :my_function, args}}
      )

      assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250
    end)

    # Return from each of the tail calls
    Enum.each(call_args, fn _arg ->
      CallTracker.handle_event(
        tracker,
        {:trace, pid, :return_from, {MyModule, :my_function, 2}, :ok}
      )
    end)

    # Return to the callee's parent
    CallTracker.handle_event(
      tracker,
      {:trace, pid, :return_to, {MyModule, :my_parent_function, 0}}
    )

    # We should get events for all three calls

    expected_ready_payload =
      {
        pid,
        {MyModule, :my_function, [:foo, :bar]},
        %{:return_from => :ok, :return_to => {MyModule, :my_parent_function, 0}}
      }

    assert_receive {:ok,
                    %CallTracker.Result{status: {:ready, ^expected_ready_payload}, warnings: []}},
                   250

    expected_ready_payload =
      {
        pid,
        {MyModule, :my_function, [:baz, :whizbang]},
        %{:return_from => :ok, :return_to => {MyModule, :my_parent_function, 0}}
      }

    assert_receive {:ok,
                    %CallTracker.Result{status: {:ready, ^expected_ready_payload}, warnings: []}},
                   250

    expected_ready_payload =
      {
        pid,
        {MyModule, :my_function, [:wibble, :wobble]},
        %{:return_from => :ok, :return_to => {MyModule, :my_parent_function, 0}}
      }

    assert_receive {:ok,
                    %CallTracker.Result{status: {:ready, ^expected_ready_payload}, warnings: []}},
                   250
  end

  test "returns error when getting return_from on a call that has yet to get a return_to" do
    {:ok, tracker} = CallTracker.start_link(send_to(self()))
    pid = :erlang.list_to_pid(~c"<0.1.0>")

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :call, {MyModule, :my_function, [:foo, :bar]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :return_from, {MyModule, :my_function, 2}, :ok}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :return_from, {MyModule, :my_function, 2}, :ok}
    )

    assert_receive {:error, {:no_callstack, ^pid, :unknown, {:return_from, :ok}}}, 250
  end

  test "uses the arg_mapper to map arguments" do
    {:ok, tracker} =
      CallTracker.start_link(send_to(self()), arg_mapper: fn [a, b] -> [a * 2, b * 3] end)

    pid = :erlang.list_to_pid(~c"<0.1.0>")

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :call, {MyModule, :my_function, [1, 2]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :return_from, {MyModule, :my_function, 2}, :ok}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :return_to, {MyModule, :my_parent_function, 0}}
    )

    expected_ready_payload =
      {
        pid,
        {MyModule, :my_function, [2, 6]},
        %{:return_from => :ok, :return_to => {MyModule, :my_parent_function, 0}}
      }

    assert_receive {:ok,
                    %CallTracker.Result{status: {:ready, ^expected_ready_payload}, warnings: []}},
                   250
  end

  test "uses the return_mapper to map return values" do
    {:ok, tracker} =
      CallTracker.start_link(send_to(self()), return_mapper: fn x -> x * 2 end)

    pid = :erlang.list_to_pid(~c"<0.1.0>")

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :call, {MyModule, :my_function, [1, 2]}}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :return_from, {MyModule, :my_function, 2}, 123}
    )

    assert_receive {:ok, %CallTracker.Result{status: :not_ready, warnings: []}}, 250

    CallTracker.handle_event(
      tracker,
      {:trace, pid, :return_to, {MyModule, :my_parent_function, 0}}
    )

    expected_ready_payload =
      {
        pid,
        {MyModule, :my_function, [1, 2]},
        %{:return_from => 246, :return_to => {MyModule, :my_parent_function, 0}}
      }

    assert_receive {:ok,
                    %CallTracker.Result{status: {:ready, ^expected_ready_payload}, warnings: []}},
                   250
  end
end
