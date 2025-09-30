defmodule Twine.Internal do
  @moduledoc false
  # This module exists so that the macros can access these functions, but there
  # is absolutely no guarantee around their stability

  defguardp is_integer_pair(value)
            when is_tuple(value) and tuple_size(value) == 2 and
                   is_integer(elem(value, 0)) and is_integer(elem(value, 1))

  alias Twine.Internal.TraceStrategies

  def run(call_ast, func) do
    with {:ok, {{m, f, a}, guard_clause}} <- decompose_match_call(call_ast),
         skip_preprocessing_args = args_to_skip_preprocessing(a, guard_clause),
         {:ok, a} <- preprocess_args(a, skip_preprocessing_args),
         :ok <- validate_guard_identifiers(a, guard_clause) do
      matchspec_ast = make_matchspec_ast({m, f, a}, guard_clause)
      func.(matchspec_ast, Enum.count(a))
    else
      {:error, error} ->
        IO.puts("#{IO.ANSI.red()}#{error}#{IO.ANSI.reset()}")

        :error
    end
  end

  def do_print_calls(spec, num_args, rate, opts) when is_integer(rate) or is_integer_pair(rate) do
    {ignore_outcome, opts} = Keyword.pop(opts, :ignore_outcome, false)

    if ignore_outcome do
      do_trace_calls(spec, num_args, rate, &TraceStrategies.simple_print/1, opts)
    else
      do_trace_calls(spec, num_args, rate, &TraceStrategies.tracked_print/1, opts)
    end
  end

  def do_recv_calls(spec, num_args, rate, opts) do
    warn_about_memory_usage(rate)

    me = self()
    {ignore_outcome, opts} = Keyword.pop(opts, :ignore_outcome, false)

    if ignore_outcome do
      do_trace_calls(
        spec,
        num_args,
        rate,
        &TraceStrategies.simple_recv(me, &1),
        opts
      )
    else
      do_trace_calls(
        spec,
        num_args,
        rate,
        &TraceStrategies.tracked_recv(me, &1),
        opts
      )
    end
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

  # End list for guards will always be two elements since we have no vars preceding the guard
  # https://github.com/elixir-lang/elixir/blob/23776d9e8f8c1c87bc012ff501340c1c75800323/lib/elixir/src/elixir_parser.yrl#L1153-L1159
  defp decompose_match_call({:when, _meta1, [{:&, _meta2, _capture}, _condition]}) do
    {:error, "Guards cannot be used with function capture syntax."}
  end

  defp decompose_match_call({:when, _meta, [call_ast, condition]}) do
    with {:ok, decomposed_call} <- decompose_call(call_ast) do
      {:ok,
       {
         decomposed_call,
         condition
       }}
    end
  end

  # End list for captures will always be two elements
  # https://github.com/elixir-lang/elixir/blob/23776d9e8f8c1c87bc012ff501340c1c75800323/lib/elixir/src/elixir_parser.yrl#L758-L759
  defp decompose_match_call(
         {:&, _meta1,
          [
            {:/, _meta2, [call_ast, arity]}
          ]}
       ) do
    with {:ok, {module, function, []}} <- decompose_call(call_ast) do
      {:ok,
       {
         {module, function, generate_fake_args(arity)},
         nil
       }}
    end
  end

  defp decompose_match_call(call_ast) do
    with {:ok, decomposed_call} <- decompose_call(call_ast) do
      {:ok, {decomposed_call, nil}}
    end
  end

  defp decompose_call(ast) do
    case Macro.decompose_call(ast) do
      :error -> {:error, "Invalid call specification"}
      decomposed -> {:ok, decomposed}
    end
  end

  defp generate_fake_args(num_args) do
    Stream.iterate(0, fn n -> n + 1 end)
    # Makes fake identifiers with the name _arg<n>
    |> Stream.map(fn n -> {String.to_atom("_arg#{n}"), [], nil} end)
    |> Stream.take(num_args)
    |> Enum.to_list()
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

  defp do_trace_calls(spec, num_args, rate, select_strategy, opts) do
    {arg_mapper, opts} = Keyword.pop(opts, :arg_mapper, nil)
    {return_mapper, opts} = Keyword.pop(opts, :return_mapper, nil)

    with :ok <- validate_arg_mapper(arg_mapper, num_args),
         :ok <- validate_return_mapper(return_mapper) do
      format_fn = select_strategy.(arg_mapper: arg_mapper, return_mapper: return_mapper)

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

  defp validate_arg_mapper(mapper, num_args) do
    if valid_mapper?(mapper, num_args) do
      :ok
    else
      {:error, "Argument mapper function must have the same arity as traced function"}
    end
  end

  defp validate_return_mapper(mapper) do
    if valid_mapper?(mapper, 1) do
      :ok
    else
      {:error, "Return mapper function must have an arity of 1"}
    end
  end

  defp valid_mapper?(nil, _num_args) do
    true
  end

  defp valid_mapper?(mapper, num_args) when is_function(mapper, num_args) do
    true
  end

  defp valid_mapper?(_mapper, num_args) when is_integer(num_args) do
    false
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
