defmodule Twine.Internal.CallTracker do
  @moduledoc false
  # This module tracks calls for the Internal module. There is absolutely no
  # guarantee around its stability

  @default_tracer_down_timeout 10_000
  @down_deferral_time 100

  defmodule State do
    @moduledoc false

    @enforce_keys [:result_callback, :tracer_down_timeout, :arg_mapper, :return_mapper]
    defstruct [
      :result_callback,
      # N.B. Despite sharing a name, this arg_mapper is not the same as the one we use in Internal, because it actually
      # accepts the _list_ of arguments. This is done this way for consistency with some the print variants.
      :arg_mapper,
      :return_mapper,
      :tracer_down_timeout,
      tracked_pids: %{},
      tracer_monitor_ref: nil,
      debug_enabled: false
    ]
  end

  defmodule TrackedPID do
    @moduledoc false

    @enforce_keys [:monitor_ref]
    defstruct [:monitor_ref, call_stack: [], pending_return_stack: []]
  end

  defmodule TrackedCall do
    @moduledoc false

    @enforce_keys [:mfa]
    defstruct [:mfa, events: %{}]
  end

  defmodule Result do
    @moduledoc false

    @enforce_keys [:status]
    defstruct [:status, warnings: []]
  end

  use GenServer

  def start_link(result_callback, opts \\ []) when is_function(result_callback, 1) do
    GenServer.start_link(__MODULE__, {result_callback, opts})
  end

  @doc """
  Log an event from the tracer. 

  Returns: :ok

  Upon successful processing of an event, the callback will be called with one of the following 
    - {:ok, %Result{status: :not_ready}} when a call has been received, but not all events have come in yet
    - {:ok, %Result{status: {:ready, ...}}} when a call has been received, and all events have come in
    - {:error, reason when an invalid event has been received

    Any :ok result might contain a set of warnings
  """
  def handle_event(tracker, event) do
    send(tracker, {:event, event})

    :ok
  end

  def stop(tracker) do
    GenServer.stop(tracker)
  end

  @doc """
  Monitor the given tracer, so we can terminate with it
  """
  def monitor_tracer(tracker, tracer_pid) do
    GenServer.call(tracker, {:monitor_tracer, tracer_pid})
  end

  @impl GenServer
  def init({result_callback, opts}) do
    debug_enabled = Keyword.get(opts, :debug_logging, false)
    tracer_down_timeout = Keyword.get(opts, :tracer_down_timeout, @default_tracer_down_timeout)
    arg_mapper = Keyword.get(opts, :arg_mapper, fn x -> x end)
    return_mapper = Keyword.get(opts, :return_mapper, fn x -> x end)

    {:ok,
     %State{
       result_callback: result_callback,
       debug_enabled: debug_enabled,
       tracer_down_timeout: tracer_down_timeout,
       arg_mapper: arg_mapper,
       return_mapper: return_mapper
     }}
  end

  @impl GenServer
  def handle_call({:monitor_tracer, tracer_pid}, _from, %State{} = state) do
    if state.tracer_monitor_ref do
      # Remove the old ref
      Process.demonitor(state.tracer_monitor_ref)
    end

    monitor_ref = Process.monitor(tracer_pid)
    state = %State{state | tracer_monitor_ref: monitor_ref}

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(msg, %State{} = state) do
    if state.debug_enabled do
      IO.puts("[TWINE DEBUG] #{inspect(msg)}")
    end

    do_handle_info(msg, state)
  end

  defp do_handle_info({:event, event_data}, %State{} = state) do
    handle_trace_event(event_data, state)
  end

  defp do_handle_info(
         {:DOWN, ref, :process, _pid, _reason},
         %State{tracer_monitor_ref: ref} = state
       ) do
    # Give the tracer some amount of time to send remaining messages before we die
    Process.send_after(self(), :stop, state.tracer_down_timeout)

    {:noreply, state}
  end

  defp do_handle_info({:DOWN, _ref, :process, pid, {:shutdown, _reason}}, %State{} = state)
       when is_pid(pid) do
    # Ignore "normal" shutdown reasons, since if we get this, chances are we're racing against a return_to
    # It does technically mean that our state has a reference to a monitor that has already resolved,
    # but that's fine, since it's not like we're going to get more than one DOWN for it.
    {:noreply, state}
  end

  defp do_handle_info({:DOWN, _ref, :process, pid, reason}, %State{} = state)
       when is_pid(pid) and reason in [:normal, :shutdown] do
    # Same as above
    {:noreply, state}
  end

  defp do_handle_info({:DOWN, ref, :process, pid, reason}, %State{} = state)
       when is_pid(pid) do
    # We defer any DOWN handling here because unlike the trace events, the order of getting a DOWN
    # is not guaranteed in any way.
    #
    # The idea here is that by sending ourselves a DOWN in @down_deferral_time,
    # we will give the tracer an opportunity to emit other events (likely an
    # exception_from), to give more meaningful outputs.
    Process.send_after(self(), {:DEFERRED_DOWN, ref, :process, pid, reason}, @down_deferral_time)
    {:noreply, state}
  end

  defp do_handle_info({:DEFERRED_DOWN, _ref, :process, pid, reason}, %State{} = state)
       when is_pid(pid) do
    handle_down(pid, reason, state)
  end

  defp do_handle_info(:stop, state) do
    {:stop, :normal, state}
  end

  defp do_handle_info(_other, %State{} = state) do
    {:noreply, state}
  end

  defp handle_trace_event(
         {:trace, pid, :call, {_module, _function, _args} = mfa},
         %State{} = state
       ) do
    {:ok, %State{} = state} = track_call(pid, mfa, state)
    state.result_callback.({:ok, %Result{status: :not_ready, warnings: []}})

    {:noreply, state}
  end

  defp handle_trace_event(
         {:trace, pid, :return_from, {_module, _function, _arg_count} = mfa, return},
         %State{} = state
       ) do
    case track_return_from(pid, mfa, return, state) do
      {:ok, state} ->
        state.result_callback.({:ok, %Result{status: :not_ready, warnings: []}})
        {:noreply, state}

      {:error, {kind, mfa}, state} ->
        state.result_callback.({:error, {kind, pid, mfa, {:return_from, return}}})
        {:noreply, state}
    end
  end

  defp handle_trace_event(
         {:trace, pid, :exception_from, {_module, _function, _arg_count} = mfa, error},
         %State{} = state
       ) do
    case track_exception_from(pid, mfa, error, state) do
      {:ok, state} ->
        state.result_callback.({:ok, %Result{status: :not_ready, warnings: []}})
        {:noreply, state}

      {:error, {kind, mfa}, state} ->
        state.result_callback.({:error, {kind, pid, mfa, {:exception_from, error}}})
        {:noreply, state}
    end
  end

  defp handle_trace_event(
         {:trace, pid, :return_to, {_module, _function, _arg_count} = mfa},
         %State{} = state
       ) do
    case track_return_to(pid, mfa, state) do
      {:ok, return_stack, %State{} = state} ->
        Enum.each(return_stack, fn %TrackedCall{} = tracked_call ->
          state.result_callback.(
            {:ok, %Result{status: {:ready, {pid, tracked_call.mfa, tracked_call.events}}}}
          )
        end)

        {:noreply, state}

      {:error, {kind, mfa, state}} ->
        state.result_callback.({:error, {kind, pid, mfa, {:return_to, mfa}}})
        {:noreply, state}
    end
  end

  defp handle_down(pid, reason, %State{} = state) when is_pid(pid) do
    case track_down(pid, reason, state) do
      {:ok, %TrackedCall{} = tracked_call, state} ->
        state.result_callback.(
          {:ok, %Result{status: {:ready, {pid, tracked_call.mfa, tracked_call.events}}}}
        )

        {:noreply, state}

      {:error, {kind, mfa}, state} ->
        state.result_callback.({:error, {kind, pid, mfa, {:DOWN, reason}}})
    end

    {:noreply, state}
  end

  defp track_call(pid, {module, function, args}, %State{} = state) do
    {%TrackedPID{} = tracked_pid, %State{} = state} = ensure_pid_tracked(pid, state)

    tracked_call = %TrackedCall{
      mfa: {module, function, state.arg_mapper.(args)}
    }

    state = put_in(state.tracked_pids[pid].call_stack, [tracked_call | tracked_pid.call_stack])

    {:ok, state}
  end

  defp track_return_from(pid, {_module, _function, _args} = mfa, return_value, %State{} = state)
       when is_pid(pid) do
    track_call_exit(
      pid,
      mfa,
      :return_from,
      state.return_mapper.(return_value),
      state
    )
  end

  defp track_exception_from(pid, {_module, _function, _args} = mfa, exception, %State{} = state)
       when is_pid(pid) do
    track_call_exit(pid, mfa, :exception_from, exception, state)
  end

  defp track_return_to(pid, {_module, _function, _args} = mfa, %State{} = state)
       when is_pid(pid) do
    with {:ok, %TrackedPID{} = tracked_pid} <- fetch_tracked_pid(pid, mfa, state) do
      return_stack =
        Enum.map(tracked_pid.pending_return_stack, fn %TrackedCall{} = call ->
          put_in(call.events[:return_to], mfa)
        end)

      # Clean up the pid if there's no unresolved calls
      if Enum.empty?(tracked_pid.call_stack) do
        state = untrack_pid(pid, state)
        {:ok, return_stack, state}
      else
        state = put_in(state.tracked_pids[pid].pending_return_stack, [])
        {:ok, return_stack, state}
      end
    end
  end

  defp track_call_exit(
         pid,
         {_module, _function, _args} = mfa,
         event_kind,
         result,
         %State{} = state
       )
       when is_pid(pid) and event_kind in [:return_from, :exception_from] do
    with {:ok, %TrackedPID{} = tracked_pid} <- fetch_tracked_pid(pid, mfa, state) do
      case pop_call_stack(tracked_pid, mfa) do
        {:ok, tracked_call, tracked_pid} ->
          tracked_call = put_in(tracked_call.events[event_kind], result)
          pending_return_stack = [tracked_call | tracked_pid.pending_return_stack]

          tracked_pid = put_in(tracked_pid.pending_return_stack, pending_return_stack)
          state = put_in(state.tracked_pids[pid], tracked_pid)

          {:ok, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp track_down(pid, reason, %State{} = state) do
    with {:ok, %TrackedPID{} = tracked_pid} <- fetch_tracked_pid(pid, :unknown, state) do
      state = untrack_pid(pid, state)

      # Prioritize the most recent call in the pending return stack, as we may have gotten an exception from there.
      # If there's nothing there, pull off the top of the callstack (which must be what crashed).
      case {tracked_pid.pending_return_stack, tracked_pid.call_stack} do
        {[%TrackedCall{} = tracked_call | _return_stack], _call_stack} ->
          tracked_call = put_in(tracked_call.events[:DOWN], reason)
          {:ok, tracked_call, state}

        {[], [%TrackedCall{} = tracked_call | _call_stack]} ->
          tracked_call = put_in(tracked_call.events[:DOWN], reason)
          {:ok, tracked_call, state}

        {[], []} ->
          {:error, {:no_callstack, :unknown}, state}
      end
    end
  end

  defp fetch_tracked_pid(pid, mfa, %State{} = state)
       when is_pid(pid) and (mfa == :unknown or (is_tuple(mfa) and tuple_size(mfa) == 3)) do
    case Map.fetch(state.tracked_pids, pid) do
      {:ok, %TrackedPID{} = tracked_pid} ->
        {:ok, tracked_pid}

      :error ->
        {:error, {:missing, mfa}, state}
    end
  end

  defp pop_call_stack(
         %TrackedPID{call_stack: []},
         {_module, _function, _args}
       ) do
    {:error, {:no_callstack, :unknown}}
  end

  defp pop_call_stack(%TrackedPID{} = tracked_pid, {_module, _function, _args} = expected_mfa) do
    [%TrackedCall{} = tracked_call | call_stack] = tracked_pid.call_stack

    if normalize_mfa(tracked_call.mfa) == normalize_mfa(expected_mfa) do
      {:ok, tracked_call, put_in(tracked_pid.call_stack, call_stack)}
    else
      {:error, {:wrong_mfa, tracked_call.mfa}}
    end
  end

  defp ensure_pid_tracked(pid, %State{} = state) when is_pid(pid) do
    case Map.fetch(state.tracked_pids, pid) do
      {:ok, tracked_pid} ->
        {tracked_pid, state}

      :error ->
        ref = Process.monitor(pid)
        tracked_pid = %TrackedPID{monitor_ref: ref}
        state = put_in(state.tracked_pids[pid], tracked_pid)

        {tracked_pid, state}
    end
  end

  defp untrack_pid(pid, %State{} = state) when is_pid(pid) do
    case Map.pop(state.tracked_pids, pid) do
      {nil, tracked_pids} ->
        put_in(state.tracked_pids, tracked_pids)

      {%TrackedPID{} = tracked_pid, tracked_pids} ->
        Process.demonitor(tracked_pid.monitor_ref)

        put_in(state.tracked_pids, tracked_pids)
    end
  end

  defp normalize_mfa({mod, function, args}) when is_integer(args) do
    {mod, function, args}
  end

  defp normalize_mfa({mod, function, args}) when is_list(args) do
    {mod, function, Enum.count(args)}
  end
end
