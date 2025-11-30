defmodule Twine.Internal.MacroHelper do
  @moduledoc false
  # This module exists to ease the implementation of Internal. There is is absolutely
  # no guarantee around its stability

  @doc """
  Decompose the matcher (the call itself) from the macro call into its constituent parts
  """
  def decompose_matcher(call_ast) do
    with {:ok, {{m, f, a}, guard_clause}} <- decompose_match_call(call_ast),
         skip_preprocessing_args = args_to_skip_preprocessing(a, guard_clause),
         {:ok, a} <- preprocess_args(a, skip_preprocessing_args),
         :ok <- validate_guard_identifiers(a, guard_clause) do
      {:ok, {{m, f, a}, guard_clause}}
    end
  end

  @doc """
  Ensure that the guard only contains valid identifiers that exist in the args list.
  """
  def validate_guard_identifiers(_args, nil) do
    :ok
  end

  def validate_guard_identifiers(args, guard_clause) do
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

  defp args_to_skip_preprocessing(_args, nil) do
    []
  end

  defp args_to_skip_preprocessing(args, guard_clause) do
    guard_identifiers = extract_identifiers(guard_clause)
    args_identifiers = extract_identifiers(args)

    MapSet.intersection(guard_identifiers, args_identifiers)
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

  defp generate_fake_args(num_args) do
    Stream.iterate(0, fn n -> n + 1 end)
    # Makes fake identifiers with the name _arg<n>
    |> Stream.map(fn n -> {String.to_atom("_arg#{n}"), [], nil} end)
    |> Stream.take(num_args)
    |> Enum.to_list()
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

  defp pinned_argument?({:^, _meta, context}) when is_list(context) do
    true
  end

  defp pinned_argument?(_other) do
    false
  end
end
