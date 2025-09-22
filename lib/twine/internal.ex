defmodule Twine.Internal do
  @moduledoc false
  # This module exists so that the macros can access these functions, but there
  # is absolutely no guarantee around their stability

  alias Twine.Internal.CallTracker
  alias Twine.Internal.Stringify

  def run(call_ast, func) do
    {{m, f, a}, guard_clause} = decompose_match_call(call_ast)
    skip_preprocessing_args = args_to_skip_preprocessing(a, guard_clause)

    with {:ok, a} <- preprocess_args(a, skip_preprocessing_args),
         :ok <- validate_guard_identifiers(a, guard_clause) do
      matchspec_ast = make_matchspec_ast({m, f, a}, guard_clause)
      func.(matchspec_ast, Enum.count(a))
    else
      {:error, error} ->
        IO.puts("#{IO.ANSI.red()}#{error}#{IO.ANSI.reset()}")

        :error
    end
  end

  def do_print_calls(spec, num_args, rate, opts) do
    do_trace_calls(spec, num_args, rate, &format_print/3, opts)
  end

  def do_recv_calls(spec, num_args, rate, opts) do
    warn_about_memory_usage(rate)

    me = self()

    do_trace_calls(
      spec,
      num_args,
      rate,
      fn pid, mfa, events ->
        format_recv(me, pid, mfa, events)
      end,
      opts
    )
  end

  defp warn_about_memory_usage({_count, _time}) do
    IO.puts(
      "#{IO.ANSI.yellow()}Using recv_calls with a rate can consume unbounded memory if messages are not consumed fast enough. You can use Twine.clear() to stop the flow of messages at any point.#{IO.ANSI.reset()}"
    )
  end

  defp warn_about_memory_usage(_count) do
    :ok
  end

  defp make_matchspec_ast({m, f, a}, guard_clause) do
    case guard_clause do
      nil ->
        quote do
          {unquote(m), unquote(f), fn unquote(a) -> :TWINE_HANDLE_ACTION end}
        end

      guard_clause ->
        quote do
          {
            unquote(m),
            unquote(f),
            fn unquote(a) when unquote(guard_clause) -> :TWINE_HANDLE_ACTION end
          }
        end
    end
  end

  # End list will always be two elements
  # https://github.com/elixir-lang/elixir/blob/main/lib/elixir/src/https://github.com/elixir-lang/elixir/blob/f93919f54a79fb523315e84c6f46899c66fe03fe/lib/elixir/src/elixir_parser.yrl#L1153-L1159elixir_parser.yrl#L1153-L1159
  defp decompose_match_call({:when, _meta, [call, condition]}) do
    {
      Macro.decompose_call(call),
      condition
    }
  end

  defp decompose_match_call(call) do
    {
      Macro.decompose_call(call),
      nil
    }
  end

  defp preprocess_args(args, ignore) do
    with :ok <- validate_args(args) do
      args =
        Enum.map(args, fn arg ->
          Macro.postwalk(arg, fn ast -> suppress_identifier_warnings(ast, ignore) end)
        end)

      {:ok, args}
    end
  end

  defp validate_guard_identifiers(_args, nil) do
    :ok
  end

  defp validate_guard_identifiers(args, guard_clause) do
    guard_identifiers = extract_identifiers(guard_clause)
    args_identifiers = extract_identifiers(args)

    missing_from_args = MapSet.difference(guard_identifiers, args_identifiers)

    if Enum.empty?(missing_from_args) do
      :ok
    else
      identifiers_msg =
        missing_from_args
        |> Enum.sort()
        |> Enum.join(", ")

      {:error,
       "Identifiers in guard must exist in argument pattern. Invalid identifiers: #{identifiers_msg}"}
    end
  end

  defp do_trace_calls(spec, num_args, rate, format_action, opts) do
    {mapper, opts} = Keyword.pop(opts, :mapper, nil)

    {:ok, tracker} =
      CallTracker.start_link(fn {:ok,
                                 %CallTracker.Result{
                                   status: {:ready, {pid, {module, function, args}, events}},
                                   warnings: warnings
                                 }} ->
        Enum.each(warnings, &print_event_warning/1)
        msg = format_action.(pid, {module, function, map_args(mapper, args)}, events)
        IO.puts(msg)
      end)

    format_fn = make_format_fn(tracker, format_action, mapper)

    with :ok <- validate_mapper(mapper, num_args) do
      recon_opts =
        opts
        |> Keyword.take([:pid])
        |> Keyword.put(:formatter, format_fn)
        |> Keyword.put(:return_to, true)
        |> Keyword.put(:scope, :local)

      {m, f, func} = spec

      matches =
        :recon_trace.calls(
          {m, f, fun_to_ms(func)},
          correct_rate(rate),
          recon_opts
        )

      match_output(matches)
    else
      {:error, error} ->
        IO.puts("#{IO.ANSI.red()}#{error}#{IO.ANSI.reset()}")

        :error
    end
  end

  # We will get a return_from for every call, so we should tolerate double the messages for completeness
  defp correct_rate({count, time}) when is_integer(count) and is_integer(time) do
    {count * 3, time}
  end

  defp correct_rate(rate) when is_integer(rate) do
    rate * 3
  end

  defp make_format_fn(tracker, action, mapper) do
    fn
      event ->
        case CallTracker.handle_event(tracker, event) do
          {:ok, %CallTracker.Result{status: :not_ready, warnings: warnings}} ->
            Enum.each(warnings, &print_event_warning/1)
            # recon_trace ignores empty strings
            ""

          {
            :ok,
            %CallTracker.Result{
              status: {:ready, {pid, {module, function, args}, events}},
              warnings: warnings
            }
          } ->
            Enum.each(warnings, &print_event_warning/1)
            action.(pid, {module, function, map_args(mapper, args)}, events)

          {:error, reason} ->
            print_event_error(reason)
            # recon_trace ignores empty strings
            ""
        end
    end
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

  defp print_event_error({kind, pid, {module, function, args}})
       when kind in [:wrong_mfa, :missing] do
    f_pid = Stringify.pid(pid)
    f_call = Stringify.call(module, function, args)

    IO.puts(
      "#{IO.ANSI.red()}Twine received an unexpected event for #{f_pid}#{IO.ANSI.yellow()} - #{f_call}#{IO.ANSI.reset()}"
    )
  end

  defp format_print(pid, {module, function, args}, events) do
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
          # Add 3 to match the deocrations we add below
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

  defp format_recv(recv_pid, call_pid, mfa, result) do
    send(recv_pid, {call_pid, mfa})

    # Recon allows us to return an empty string and it won't do anything with it
    ""
  end

  defp validate_args(args) do
    invalid =
      args
      |> Enum.map(&pinned_argument?/1)
      |> Enum.any?()

    # recon_trace's pattern matching does not support the pinning that elixir
    # uses. Haven't dug into why, but it fails with a :badarg rather
    # unceremoniously
    if invalid do
      {:error, "Call cannot contain a pattern that uses the pin operator (^)"}
    else
      :ok
    end
  end

  defp validate_mapper(nil, _num_args) do
    :ok
  end

  defp validate_mapper(mapper, num_args) when is_function(mapper, num_args) do
    :ok
  end

  defp validate_mapper(_mapper, num_args) when is_integer(num_args) do
    {:error, "Mapper function must have the same arity as traced function"}
  end

  def match_output(0) do
    IO.puts(
      "#{IO.ANSI.red()}No functions matched, check that it is specified correctly#{IO.ANSI.reset()}"
    )

    :error
  end

  def match_output(n) do
    IO.puts("#{IO.ANSI.green()}#{n} function(s) matched, waiting for calls...#{IO.ANSI.reset()}")

    :ok
  end

  defp args_to_skip_preprocessing(_args, nil) do
    []
  end

  defp args_to_skip_preprocessing(args, guard_clause) do
    guard_identifiers = extract_identifiers(guard_clause)
    args_identifiers = extract_identifiers(args)

    MapSet.intersection(guard_identifiers, args_identifiers)
  end

  defp extract_identifiers(ast) do
    {_new_ast, acc} =
      Macro.traverse(
        ast,
        MapSet.new(),
        fn a, b -> {a, b} end,
        fn
          {name, meta, context}, acc when is_atom(name) and is_atom(context) ->
            {{name, meta, context}, MapSet.put(acc, name)}

          other, acc ->
            {other, acc}
        end
      )

    acc
  end

  defp suppress_identifier_warnings({name, meta, context}, ignore)
       when is_atom(name) and is_atom(context) do
    # Prepend an underscore to suppress warnings
    if not String.starts_with?(Atom.to_string(name), "_") and not Enum.member?(ignore, name) do
      {String.to_atom("_#{name}"), meta, context}
    else
      {name, meta, context}
    end
  end

  defp suppress_identifier_warnings(other, _ignore) do
    other
  end

  defp pinned_argument?({:^, _meta, context}) when is_list(context) do
    true
  end

  defp pinned_argument?(_other) do
    false
  end

  # Lifted from recon_trace and translated to elixir, primarily to support 
  # action transformation
  #
  # License for recon_trace:
  #
  # Copyright (c) 2012-2024, Fred Hebert
  # All rights reserved.
  #
  # Redistribution and use in source and binary forms, with or without modification,
  # are permitted provided that the following conditions are met:
  #
  #   Redistributions of source code must retain the above copyright notice, this
  #   list of conditions and the following disclaimer.
  #
  #   Redistributions in binary form must reproduce the above copyright notice, this
  #   list of conditions and the following disclaimer in the documentation and/or
  #   other materials provided with the distribution.
  #
  #   Neither the name of the copyright holder nor the names of its contributors may
  #   be used to endorse or promote products derived from this software without
  #   specific prior written permission.
  #
  # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
  # ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
  # WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
  # DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
  # ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
  # (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  # LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
  # ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  # SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  defp fun_to_ms(shell_fun) when is_function(shell_fun) do
    case :erl_eval.fun_data(shell_fun) do
      {:fun_data, import_list, clauses} ->
        case :ms_transform.transform_from_shell(:dbg, clauses, import_list) do
          {:error, [{_, [{_, _, code} | _]} | _], _} ->
            IO.puts(
              "#{IO.ANSI.red()}Matchspec error: #{:ms_transform.format_error(code)}#{IO.ANSI.reset()}"
            )

            {:error, :transform_error}

          match_function ->
            Enum.map(match_function, &inject_actions/1)
        end
    end
  end

  # Per the erlang docs, "ActionCall" must wrap atoms in tuples. Normally recon_trace 
  # solves this with doing return_trace(), but we can't do that in elixir shellfuns. 
  # The easiest way to do it is to just transform a sentinel atom into the actions we want
  #
  # https://www.erlang.org/doc/apps/erts/match_spec
  defp inject_actions({head, conditions, actions}) do
    actions =
      Enum.flat_map(actions, fn
        :TWINE_HANDLE_ACTION ->
          [{:return_trace}, {:exception_trace}]

        action ->
          [action]
      end)

    {head, conditions, actions}
  end
end
