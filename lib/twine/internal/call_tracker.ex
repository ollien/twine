defmodule Twine.Internal.CallTracker do
  @moduledoc false
  # This module tracks calls for the Internal module. There is absolutely no
  # guarantee around its stability

  @default_tracer_down_timeout 10_000

  defmodule State do
    @moduledoc false

    @enforce_keys [:result_callback, :tracer_down_timeout]
    defstruct [
      :result_callback,
      :tracer_down_timeout,
      tracked_pids: %{},
      tracer_monitor_ref: nil,
      debug_enabled: false
    ]
  end

  defmodule Entry do
    @moduledoc false

    @enforce_keys [:mfa, :monitor_ref]
    defstruct [:mfa, :monitor_ref, events: %{}]
  end

  defmodule Result do
    @moduledoc false

    @enforce_keys [:status]
    defstruct [:status, warnings: []]
  end

  use GenServer

  defmacrop fetch_from_mailbox(pattern, timeout \\ 100) do
    quote do
      receive do
        unquote(pattern) = value -> value
      after
        unquote(timeout) -> nil
      end
    end
  end

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

    {:ok,
     %State{
       result_callback: result_callback,
       debug_enabled: debug_enabled,
       tracer_down_timeout: tracer_down_timeout
     }}
  end

  @impl GenServer
  def handle_call({:monitor_tracer, tracer_pid}, _from, %State{} = state) do
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

  defp do_handle_info(
         {:event, {:trace, pid, :call, {_module, _function, _args} = mfa}},
         %State{} = state
       ) do
    old_entry = Map.get(state.tracked_pids, pid)
    monitor_ref = Process.monitor(pid)

    state =
      put_in(state.tracked_pids[pid], %Entry{mfa: mfa, monitor_ref: monitor_ref, events: %{}})

    case old_entry do
      nil ->
        state.result_callback.({:ok, %Result{status: :not_ready}})
        {:noreply, state}

      %Entry{} ->
        warning = {:overwrote_call, pid, old_entry.mfa}
        state.result_callback.({:ok, %Result{status: :not_ready, warnings: [warning]}})

        {:noreply, state}
    end
  end

  defp do_handle_info(
         {:event, {:trace, pid, :return_from, {_module, _function, _arg_count} = mfa, return}},
         %State{} = state
       ) do
    {reply, state} =
      log_event(state, pid, normalize_mfa(mfa), :return_from, return)

    state.result_callback.(reply)

    {:noreply, state}
  end

  defp do_handle_info(
         {:event, {:trace, pid, :exception_from, {_module, _function, _arg_count} = mfa, error}},
         %State{} = state
       ) do
    {reply, state} =
      log_event(state, pid, normalize_mfa(mfa), :exception_from, error)

    state.result_callback.(reply)

    {:noreply, state}
  end

  defp do_handle_info(
         {:event, {:trace, pid, :return_to, {_module, _function, _arg_count} = mfa}},
         %State{} = state
       ) do
    down_msg = fetch_from_mailbox({:DOWN, _ref, :process, ^pid, _reason})
    # If we get a return_to, there are some DOWN Messages which are better suited,
    # such as stacktraces
    if down_msg != nil and prioritize_down?(down_msg) do
      handle_down(down_msg, state)
    else
      {reply, state} = log_event(state, pid, :return_to, mfa)

      state.result_callback.(reply)
      {:noreply, state}
    end
  end

  defp do_handle_info(
         {:DOWN, ref, :process, _pid, _reason},
         %State{tracer_monitor_ref: ref} = state
       ) do
    # Give the tracer some amount of time to send remaining messages before we die
    Process.send_after(self(), :stop, state.tracer_down_timeout)

    {:noreply, state}
  end

  defp do_handle_info(:stop, state) do
    {:stop, :normal, state}
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

  defp do_handle_info({:DOWN, _ref, :process, pid, _reason} = down_msg, %State{} = state)
       when is_pid(pid) do
    return_to_msg =
      fetch_from_mailbox({:event, {:trace, ^pid, :return_to, {_module, _function, _arg_count}}})

    # If we get a DOWN, there are some return_to we are better off handling, such as if we have a noproc.
    if return_to_msg != nil and not prioritize_down?(down_msg) do
      handle_info(return_to_msg, state)
    else
      handle_down(down_msg, state)
    end
  end

  defp do_handle_info(_other, %State{} = state) do
    {:noreply, state}
  end

  defp handle_down({:DOWN, ref, :process, pid, reason}, %State{} = state) do
    case state.tracked_pids[pid] do
      nil ->
        {:noreply, state}

      %Entry{monitor_ref: ^ref} ->
        {result, state} = log_event(state, pid, :DOWN, reason)

        case result do
          {:ok, %Result{status: {:ready, _data}}} ->
            state = %{(%State{} = state) | tracked_pids: Map.delete(state.tracked_pids, pid)}
            state.result_callback.(result)
            {:noreply, state}

          _other ->
            {:noreply, state}
        end
    end
  end

  defp log_event(%State{} = state, pid, kind, value) do
    log_event(state, pid, :unknown, kind, value)
  end

  defp log_event(%State{} = state, pid, normalized_mfa, kind, value) do
    with {:ok, entry} <- fetch_call(state, pid, normalized_mfa) do
      entry = put_in(entry.events[kind], value)
      result = result_after_log(pid, entry)

      state =
        case result do
          {:ok, %Result{status: {:ready, _info}}} ->
            {entry, tracked_pids} = Map.pop(state.tracked_pids, pid)
            # This can't be nil since we just fetched the pid from state earlier
            Process.demonitor(entry.monitor_ref)

            %State{state | tracked_pids: tracked_pids}

          _other ->
            put_in(state.tracked_pids[pid], entry)
        end

      {result, state}
    else
      {:error, {error_kind, pid, mfa}} ->
        error = {:error, {error_kind, pid, mfa, {kind, value}}}

        {error, state}

      error ->
        {error, state}
    end
  end

  defp fetch_call(%State{} = state, pid, normalized_mfa) do
    with %Entry{} = entry <-
           Map.get(state.tracked_pids, pid, {:error, {:missing, pid, normalized_mfa}}),
         :ok <- validate_expected_mfa(entry, pid, normalized_mfa) do
      {:ok, entry}
    end
  end

  defp validate_expected_mfa(%Entry{}, _pid, :unknown) do
    :ok
  end

  defp validate_expected_mfa(%Entry{} = entry, pid, normalized_mfa) do
    case normalize_mfa(entry.mfa) do
      ^normalized_mfa ->
        :ok

      _other ->
        {:error, {:wrong_mfa, pid, entry.mfa}}
    end
  end

  defp result_after_log(pid, entry) do
    # We must have return_to'd or return_from'd, otherwise we haven't gotten all the events yet.
    case entry.events do
      %{:return_to => _return_to, :return_from => _return_from} ->
        {:ok, %Result{status: {:ready, {pid, entry.mfa, entry.events}}}}

      %{:return_to => _return_to, :exception_from => _exception_from} ->
        {:ok, %Result{status: {:ready, {pid, entry.mfa, entry.events}}}}

      %{:DOWN => _down, :exception_from => _exception_from} ->
        {:ok, %Result{status: {:ready, {pid, entry.mfa, entry.events}}}}

      %{} ->
        {:ok, %Result{status: :not_ready}}
    end
  end

  defp normalize_mfa({mod, function, args}) when is_integer(args) do
    {mod, function, args}
  end

  defp normalize_mfa({mod, function, args}) when is_list(args) do
    {mod, function, Enum.count(args)}
  end

  defp prioritize_down?({:DOWN, _ref, :process, _pid, {:shutdown, _reason}}) do
    false
  end

  defp prioritize_down?({:DOWN, _ref, :process, _pid, reason})
       when reason in [:normal, :shutdown, :noproc] do
    false
  end

  defp prioritize_down?({:DOWN, _ref, :process, _pid, _other}) do
    true
  end
end
