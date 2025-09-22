defmodule Twine.Internal.CallTracker do
  @moduledoc false
  # This module tracks calls for the Internal module. There is absolutely no
  # guarantee around its stability

  defmodule State do
    @moduledoc false

    @enforce_keys [:down_callback]
    defstruct [
      :down_callback,
      tracked_pids: %{}
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

  def start_link(down_callback) when is_function(down_callback, 1) do
    GenServer.start_link(__MODULE__, down_callback)
  end

  @doc """
  Log an event from the tracer. 

  Returns:
    - {:ok, %Result{status: :not_ready}} when a call has been received, but not all events have come in yet
    - {:ok, %Result{status: {:ready, ...}}} when a call has been received, and all events have come in
    - {:error, reason when an invalid event has been received

    Any :ok result might contain a set of warnings
  """
  def handle_event(tracker, event) do
    GenServer.call(tracker, {:handle_event, event})
  end

  @impl GenServer
  def init(down_callback) do
    {:ok, %State{down_callback: down_callback}}
  end

  @impl GenServer
  def handle_call(
        {:handle_event, {:trace, pid, :call, {_module, _function, _args} = mfa}},
        _from,
        %State{} = state
      ) do
    old_entry = Map.get(state.tracked_pids, pid)
    monitor_ref = Process.monitor(pid)

    state =
      put_in(state.tracked_pids[pid], %Entry{mfa: mfa, monitor_ref: monitor_ref, events: %{}})

    case old_entry do
      nil ->
        {:reply, {:ok, %Result{status: :not_ready}}, state}

      %Entry{} ->
        warning = {:overwrote_call, pid, old_entry.mfa}

        {:reply, {:ok, %Result{status: :not_ready, warnings: [warning]}}, state}
    end
  end

  @impl GenServer
  def handle_call(
        {:handle_event,
         {:trace, pid, :return_from, {_module, _function, _arg_count} = mfa, return}},
        _from,
        %State{} = state
      ) do
    {reply, state} = log_event(state, pid, normalize_mfa(mfa), :return_from, return)

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call(
        {:handle_event,
         {:trace, pid, :exception_from, {_module, _function, _arg_count} = mfa, error}},
        _from,
        %State{} = state
      ) do
    {reply, state} = log_event(state, pid, normalize_mfa(mfa), :exception_from, error)

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call(
        {:handle_event, {:trace, pid, :return_to, {_module, _function, _arg_count} = mfa}},
        _from,
        %{} = state
      ) do
    {reply, state} = log_event(state, pid, :return_to, mfa)

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, {:shutdown, _reason}}, %State{} = state)
      when is_pid(pid) do
    # Ignore "normal" shutdown reasons, since if we get this, chances are we're racing against a return_to
    # It does technically mean that our state has a reference to a monitor that has already resolved,
    # but that's fine, since it's not like we're going to get more than one DOWN for it.
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, %State{} = state)
      when is_pid(pid) and reason in [:normal, :shutdown] do
    # Same as above
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, %State{} = state) when is_pid(pid) do
    case state.tracked_pids[pid] do
      nil ->
        {:noreply, state}

      %Entry{monitor_ref: ^ref} ->
        {result, state} = log_event(state, pid, :DOWN, reason)

        case result do
          {:ok, %Result{status: {:ready, _data}}} ->
            state = %State{state | tracked_pids: Map.delete(state.tracked_pids, pid)}
            state.down_callback.(result)
            {:noreply, state}

          _other ->
            {:noreply, state}
        end
    end
  end

  def handle_info(_other, %State{} = state) do
    {:noreply, state}
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
      error -> {error, state}
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
end
