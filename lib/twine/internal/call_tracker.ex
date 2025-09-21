defmodule Twine.Internal.CallTracker do
  @moduledoc false
  # This module tracks calls for the Internal module. There is absolutely no
  # guarantee around its stability

  defmodule Entry do
    @moduledoc false

    @enforce_keys [:mfa]
    defstruct [:mfa, events: %{}]
  end

  defmodule Result do
    @moduledoc false

    @enforce_keys [:status]
    defstruct [:status, warnings: []]
  end

  use Agent

  def start_link() do
    Agent.start_link(fn -> %{} end)
  end

  @doc """
  Log an event from the tracer. 

  Returns:
    - {:ok, %Result{status: :not_ready}} when a call has been received, but not all events have come in yet
    - {:ok, %Result{status: {:ready, ...}}} when a call has been received, and all events have come in
    - {:error, reason when an invalid event has been received

    Any :ok result might contain a set of warnings
  """
  def handle_event(tracker, {:trace, pid, :call, {_module, _function, _args} = mfa}) do
    old_entry =
      Agent.get_and_update(tracker, fn %{} = state ->
        old_entry = Map.get(state, pid)

        state =
          Map.put(
            state,
            pid,
            %Entry{mfa: mfa, events: %{}}
          )

        {old_entry, state}
      end)

    case old_entry do
      nil ->
        {:ok, %Result{status: :not_ready}}

      %Entry{} ->
        warning = {:overwrote_call, pid, old_entry.mfa}

        {:ok, %Result{status: :not_ready, warnings: [warning]}}
    end
  end

  def handle_event(
        tracker,
        {:trace, pid, :return_from, {_module, _function, _arg_count} = mfa, return}
      ) do
    log_event(tracker, pid, normalize_mfa(mfa), :return_from, return)
  end

  def handle_event(
        tracker,
        {:trace, pid, :exception_from, {_module, _function, _arg_count} = mfa, error}
      ) do
    log_event(tracker, pid, normalize_mfa(mfa), :exception_from, error)
  end

  def handle_event(
        tracker,
        {:trace, pid, :return_to, {_module, _function, _arg_count} = mfa}
      ) do
    log_event(tracker, pid, :return_to, mfa)
  end

  defp log_event(tracker, pid, kind, value) do
    log_event(tracker, pid, :unknown, kind, value)
  end

  defp log_event(tracker, pid, normalized_mfa, kind, value) do
    Agent.get_and_update(tracker, fn %{} = state ->
      with {:ok, entry} <- fetch_call(state, pid, normalized_mfa) do
        entry = put_in(entry.events[kind], value)
        result = result_after_log(pid, entry)

        state =
          case result do
            {:ok, %Result{status: {:ready, _info}}} -> Map.delete(state, pid)
            _other -> %{state | pid => entry}
          end

        {result, state}
      else
        error -> {error, state}
      end
    end)
  end

  defp fetch_call(%{} = state, pid, normalized_mfa) do
    with %Entry{} = entry <- Map.get(state, pid, {:error, {:missing, pid, normalized_mfa}}),
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
