defmodule Twine.Internal do
  @moduledoc false
  # This module exists so that the macros can access these functions, but there
  # is absolutely no guarantee around their stability

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

  def do_print_calls(func, num_args, rate, opts) do
    do_trace_calls(func, num_args, rate, &format_print/2, opts)
  end

  def do_recv_calls(func, num_args, rate, opts) do
    warn_about_memory_usage(rate)

    me = self()

    do_trace_calls(
      func,
      num_args,
      rate,
      fn pid, mfa ->
        format_recv(me, pid, mfa)
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
          {unquote(m), unquote(f), fn unquote(a) -> :return_trace end}
        end

      guard_clause ->
        quote do
          {
            unquote(m),
            unquote(f),
            fn unquote(a) when unquote(guard_clause) -> :return_trace end
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

  defp do_trace_calls(func, num_args, rate, format_action, opts) do
    {mapper, opts} = Keyword.pop(opts, :mapper, nil)

    with :ok <- validate_mapper(mapper, num_args) do
      recon_opts =
        opts
        |> Keyword.take([:pid])
        |> Keyword.put(:formatter, make_format_fn(format_action, mapper))
        |> Keyword.put(:scope, :local)

      matches =
        :recon_trace.calls(
          func,
          rate,
          recon_opts
        )

      match_output(matches)
    else
      {:error, error} ->
        IO.puts("#{IO.ANSI.red()}#{error}#{IO.ANSI.reset()}")

        :error
    end
  end

  defp make_format_fn(action, mapper) do
    fn {:trace, pid, :call, {module, function, args}} ->
      action.(pid, {module, function, map_args(mapper, args)})
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

  defp format_print(pid, {module, function, args}) do
    f_pid = "#{IO.ANSI.light_red()}#{inspect(pid)}#{IO.ANSI.reset()}"

    # Can't use Atom.to_string(module)/#{module} as that will give the Elixir prefix, which is not great output
    f_module = "#{IO.ANSI.cyan()}#{inspect(module)}#{IO.ANSI.reset()}"
    f_function = "#{IO.ANSI.green()}#{function}#{IO.ANSI.reset()}"

    f_args =
      args
      |> Enum.map(fn arg ->
        arg
        |> inspect(
          syntax_colors: IO.ANSI.syntax_colors(),
          pretty: true,
          limit: :infinity,
          printable_limit: :infinity
        )
        # We escape tildes because recon_trace uses io:format, which uses ~ as an escape sequence.
        |> String.replace("~", "~~")
      end)
      |> Enum.join(", ")

    "[#{DateTime.utc_now()}] #{f_pid} - #{f_module}.#{f_function}(#{f_args})\n"
  end

  defp format_recv(recv_pid, call_pid, mfa) do
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
end
