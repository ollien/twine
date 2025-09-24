defmodule Twine.Internal.TraceStrategies do
  @moduledoc false
  # This module exists to ease the implementation of Internal. There is is absolutely
  # no guarantee around its stability

  alias Twine.Internal.CallTracker
  alias Twine.Internal.Stringify

  def simple_print(opts \\ []) do
    mapper = Keyword.get(opts, :mapper)

    fn
      {:trace, pid, :call, {module, function, args}} ->
        print_simple_message(pid, {module, function, map_args(mapper, args)})

      _other ->
        :ok
    end
  end

  def simple_recv(recv_pid, opts \\ []) do
    mapper = Keyword.get(opts, :mapper)

    fn
      {:trace, pid, :call, {module, function, args}} ->
        # TODO: this can't be reused
        recv(recv_pid, pid, {module, function, map_args(mapper, args)})

      _other ->
        :ok
    end
  end

  def tracked_print(opts \\ []) do
    mapper = Keyword.get(opts, :mapper)

    {:ok, tracker} =
      CallTracker.start_link(fn result ->
        handle_calltracker_result(result, &print_tracked_message/3, mapper)
      end)

    fn
      event ->
        CallTracker.handle_event(tracker, event)

        # recon_trace ignores "" values
        ""
    end
  end

  def tracked_recv(recv_pid, opts \\ []) do
    mapper = Keyword.get(opts, :mapper)

    recv = fn call_pid, mfa, events ->
      recv(recv_pid, call_pid, mfa, events)
    end

    {:ok, tracker} =
      CallTracker.start_link(fn result ->
        handle_calltracker_result(result, recv, mapper)
      end)

    fn
      event ->
        CallTracker.handle_event(tracker, event)

        # recon_trace ignores "" values
        ""
    end
  end

  defp print_tracked_message(pid, {module, function, args}, events) do
    timestamp = "#{DateTime.utc_now()}]"
    timestamp_padding = String.duplicate(" ", String.length(timestamp))

    outcome_msg =
      case events do
        %{return_from: return_from} ->
          "#{IO.ANSI.cyan()}Returned#{IO.ANSI.reset()}: #{Stringify.term(return_from)}"

        %{exception_from: exception_from} ->
          "#{IO.ANSI.red()}Raised Exception#{IO.ANSI.reset()}: #{Stringify.term(exception_from)}"
      end

    return_msg =
      case events do
        %{return_to: {return_module, return_function, return_args}} ->
          "#{IO.ANSI.cyan()}Returned to#{IO.ANSI.reset()}: #{Stringify.call(return_module, return_function, return_args)}"

        # If we have a DOWN, we probably have the error in the exception
        %{DOWN: {_error, stacktrace}} ->
          f_stacktrace = Exception.format_stacktrace(stacktrace)
          # Add 3 to match the decorations we add below
          stacktrace_padding =
            timestamp_padding <> String.duplicate(" ", String.length("Process Exited: ") + 3)

          f_stacktrace =
            Regex.replace(~r/^\s*/m, f_stacktrace, stacktrace_padding)
            |> String.trim_leading()

          "#{IO.ANSI.red()}Process Exited#{IO.ANSI.reset()}: #{f_stacktrace}"

        %{DOWN: reason} ->
          "#{IO.ANSI.red()}Process Exited#{IO.ANSI.reset()}: #{Stringify.term(reason)}"
      end

    f_pid = Stringify.pid(pid)

    f_call =
      Stringify.call(module, function, args)
      |> String.replace("~", "~~")

    # Must convert this to a charlist so Erlang shows the unicode chars correctly
    String.to_charlist(
      "#{timestamp} ┌ #{f_pid} - #{f_call}\n" <>
        "#{timestamp_padding} ├ #{outcome_msg}\n" <>
        "#{timestamp_padding} └ #{return_msg}\n"
    )
  end

  defp print_simple_message(pid, {module, function, args}) do
    f_pid = "#{IO.ANSI.light_red()}#{inspect(pid)}#{IO.ANSI.reset()}"

    f_call =
      Stringify.call(module, function, args)
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

    # Recon allows us to return an empty string and it won't do anything with it
    ""
  end

  defp handle_calltracker_result(result, format_action, mapper) do
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

        format_action.(pid, {module, function, map_args(mapper, args)}, events)
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

  defp print_event_warning({:overwrote_call, pid, {module, function, args}}) do
    f_pid = Stringify.pid(pid)
    f_call = Stringify.call(module, function, args)

    IO.puts(
      "#{IO.ANSI.yellow()}Twine received call event before previous call completed on #{f_pid}#{IO.ANSI.yellow()}. Previous call: #{f_call}#{IO.ANSI.reset()}"
    )
  end

  defp print_event_error({kind, pid, {module, function, args}, message})
       when kind in [:wrong_mfa, :missing] do
    f_pid = Stringify.pid(pid)
    f_call = Stringify.call(module, function, args)

    IO.puts(
      "#{IO.ANSI.red()}Twine received an unexpected event for #{f_pid}#{IO.ANSI.red()} - #{f_call} #{IO.ANSI.light_black()}(#{inspect(message)}#{IO.ANSI.reset()}"
    )
  end

  defp print_event_error({kind, pid, :unknown, message})
       when kind in [:wrong_mfa, :missing] do
    f_pid = Stringify.pid(pid)

    IO.puts(
      "#{IO.ANSI.red()}Twine received an unexpected event for #{f_pid}#{IO.ANSI.red()} - callsite could not be determined #{IO.ANSI.light_black()}(#{inspect(message)}#{IO.ANSI.reset()}"
    )
  end
end
