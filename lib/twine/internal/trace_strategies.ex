defmodule Twine.Internal.TraceStrategies do
  @moduledoc false
  # This module exists to ease the implementation of Internal. There is is absolutely
  # no guarantee around its stability

  alias Twine.Internal.CallTracker
  alias Twine.Internal.Stringify

  defmodule Strategy do
    @moduledoc false

    @enforce_keys [:format_fn, :cleanup_fn]
    defstruct [
      :format_fn,
      # Strategies usually clean up on their own, but if we need to force it, this is an option. format_fn should not be used afterwards.
      :cleanup_fn
    ]
  end

  @doc """
  The "simple print" strategy prints the call without waiting for any results.
  """
  def simple_print(opts \\ []) do
    arg_mapper = Keyword.get(opts, :arg_mapper)

    format_fn = fn
      {:trace, pid, :call, {module, function, args}} ->
        print_simple_message(pid, {module, function, map_args(arg_mapper, args)})

      _other ->
        ""
    end

    %Strategy{
      format_fn: format_fn,
      cleanup_fn: fn -> :ok end
    }
  end

  @doc """
  The "simple recv" strategy sends the call without waiting for any results.
  """
  def simple_recv(recv_pid, opts \\ []) do
    arg_mapper = Keyword.get(opts, :arg_mapper)

    format_fn = fn
      {:trace, pid, :call, {module, function, args}} ->
        recv(recv_pid, pid, {module, function, map_args(arg_mapper, args)})

        # Recon allows us to return an empty string and it won't do anything with it
        ""

      _other ->
        ""
    end

    %Strategy{
      format_fn: format_fn,
      cleanup_fn: fn -> :ok end
    }
  end

  @doc """
  The "tracked print" strategy prints the call and waits for results.
  """
  def tracked_print(opts \\ []) do
    arg_mapper = Keyword.get(opts, :arg_mapper)
    return_mapper = Keyword.get(opts, :return_mapper)
    debug_logging = Keyword.get(opts, :debug_logging, false)

    {:ok, tracker} =
      CallTracker.start_link(
        fn result ->
          handle_calltracker_result(result, &print_tracked_message/3, arg_mapper, return_mapper)
        end,
        debug_logging: debug_logging
      )

    format_fn = fn
      event ->
        CallTracker.monitor_tracer(tracker, self())
        CallTracker.handle_event(tracker, event)

        # recon_trace ignores "" values
        ""
    end

    %Strategy{
      format_fn: format_fn,
      cleanup_fn: fn -> CallTracker.stop(tracker) end
    }
  end

  @doc """
  The "tracked recv" strategy sends the call and waits for results.
  """
  def tracked_recv(recv_pid, opts \\ []) do
    arg_mapper = Keyword.get(opts, :arg_mapper)
    return_mapper = Keyword.get(opts, :return_mapper)
    debug_logging = Keyword.get(opts, :debug_logging, false)

    recv = fn call_pid, mfa, events ->
      recv(recv_pid, call_pid, mfa, events)

      # handle_calltracker_result needs to not print anything
      ""
    end

    {:ok, tracker} =
      CallTracker.start_link(
        fn result ->
          handle_calltracker_result(result, recv, arg_mapper, return_mapper)
        end,
        debug_logging: debug_logging
      )

    format_fn = fn
      event ->
        CallTracker.monitor_tracer(tracker, self())
        CallTracker.handle_event(tracker, event)

        # recon_trace ignores "" values
        ""
    end

    %Strategy{
      format_fn: format_fn,
      cleanup_fn: fn -> CallTracker.stop(tracker) end
    }
  end

  defp print_tracked_message(pid, {module, function, args}, events) do
    timestamp = "[#{DateTime.utc_now()}]"
    timestamp_width = String.length(timestamp)

    outcome_msg =
      case events do
        %{return_from: return_from} ->
          Stringify.decorated_block(
            IO.ANSI.cyan(),
            "Returned",
            Stringify.term(return_from),
            timestamp_width,
            "├",
            decorate_edge: true
          )

        %{exception_from: exception_from} ->
          Stringify.decorated_block(
            IO.ANSI.red(),
            "Raised Exception",
            Stringify.term(exception_from),
            timestamp_width,
            "├",
            decorate_edge: true
          )
      end

    return_msg =
      case events do
        %{return_to: {return_module, return_function, return_args}} ->
          Stringify.decorated_block(
            IO.ANSI.cyan(),
            "Returned to",
            Stringify.call(return_module, return_function, return_args),
            timestamp_width,
            "└"
          )

        # If we have a DOWN, we probably have the error in the exception
        %{DOWN: {_error, stacktrace}} ->
          Stringify.decorated_block(
            IO.ANSI.red(),
            "Process Terminated",
            Exception.format_stacktrace(stacktrace),
            timestamp_width,
            "└",
            replace_indentation: true
          )

        %{DOWN: reason} ->
          Stringify.decorated_block(
            IO.ANSI.red(),
            "Process Terminated",
            Stringify.term(reason),
            timestamp_width,
            "└"
          )
      end

    f_pid = Stringify.pid(pid)

    f_call =
      Stringify.multiline_call(module, function, args)
      # Don't need to escape tildes here since we print it ourselves
      # Add 1 for the space before decorations on subsequent lines
      |> Stringify.indented_block(timestamp_width + 1, dedent_first_line: true)

    "#{timestamp} #{f_pid} - #{f_call}\n" <>
      "#{outcome_msg}\n" <>
      "#{return_msg}\n"
  end

  defp print_simple_message(pid, {module, function, args}) do
    f_pid = "#{IO.ANSI.light_red()}#{inspect(pid)}#{IO.ANSI.reset()}"

    f_call =
      Stringify.multiline_call(module, function, args)
      # Escape tildes for erlang
      |> String.replace("~", "~~")

    "[#{DateTime.utc_now()}] #{f_pid} - #{f_call}\n"
  end

  defp recv(recv_pid, call_pid, mfa, events \\ %{}) do
    outcome =
      case events do
        %{return_from: return_from, return_to: return_to} ->
          %Twine.TracedCallReturned{return_value: return_from, return_to: return_to}

        %{exception_from: exception_from, return_to: return_to} ->
          %Twine.TracedCallExceptionCaught{exception: exception_from, return_to: return_to}

        %{exception_from: exception_from, DOWN: exit_reason} ->
          %Twine.TracedCallCrashed{exception: exception_from, exit_reason: exit_reason}

        %{} ->
          nil
      end

    msg = %Twine.TracedCall{
      pid: call_pid,
      mfa: mfa,
      outcome: outcome
    }

    send(recv_pid, msg)
  end

  defp handle_calltracker_result(result, format_action, arg_mapper, return_mapper) do
    case result do
      {:ok, %CallTracker.Result{status: :not_ready, warnings: warnings}} ->
        Enum.each(warnings, &print_event_warning/1)

      {
        :ok,
        %CallTracker.Result{
          status: {:ready, {pid, {module, function, args}, events}},
          warnings: warnings
        }
      } ->
        Enum.each(warnings, &print_event_warning/1)

        events = map_events(events, return_mapper)

        format_action.(pid, {module, function, map_args(arg_mapper, args)}, events)
        |> IO.puts()

      {:error, reason} ->
        print_event_error(reason)
    end

    :ok
  end

  defp map_args(nil, args) do
    args
  end

  defp map_args(mapper, args) do
    res = apply(mapper, args)

    cond do
      is_list(res) -> res
      is_tuple(res) -> Tuple.to_list(res)
    end
  end

  defp map_events(%{} = events, return_mapper) do
    events
    |> Enum.map(fn
      {:return_from, return_value} when not is_nil(return_mapper) ->
        {:return_from, return_mapper.(return_value)}

      other ->
        other
    end)
    |> Map.new()
  end

  defp print_event_warning({:overwrote_call, pid, {module, function, args}}) do
    f_pid = Stringify.pid(pid)
    f_call = Stringify.call(module, function, args)

    IO.puts(
      "#{IO.ANSI.yellow()}Twine received call event before previous call completed on #{f_pid}#{IO.ANSI.yellow()}. Previous call: #{f_call}#{IO.ANSI.reset()}"
    )
  end

  defp print_event_error({kind, pid, {module, function, args}, message})
       when kind in [:wrong_mfa, :missing, :no_callstack] do
    f_pid = Stringify.pid(pid)
    f_call = Stringify.call(module, function, args)

    IO.puts(
      "#{IO.ANSI.red()}Twine received an unexpected event for #{f_pid}#{IO.ANSI.red()} - #{f_call} #{IO.ANSI.light_black()}(#{inspect(message)}#{IO.ANSI.reset()}"
    )
  end

  defp print_event_error({kind, pid, :unknown, message})
       when kind in [:wrong_mfa, :missing, :no_callstack] do
    f_pid = Stringify.pid(pid)

    IO.puts(
      "#{IO.ANSI.red()}Twine received an unexpected event for #{f_pid}#{IO.ANSI.red()} - callsite could not be determined #{IO.ANSI.light_black()}(#{inspect(message)}#{IO.ANSI.reset()}"
    )
  end
end
