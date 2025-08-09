defmodule Twine.Internal do
  @moduledoc false
  # This module exists so that the macros can access these functions, but there
  # is absolutely no guarantee around their stability

  def run(args, func) do
    with {:ok, args} <- preprocess_args(args) do
      func.(args)
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

  defp preprocess_args(args) do
    with :ok <- validate_args(args) do
      args =
        Enum.map(args, fn arg ->
          Macro.postwalk(arg, &suppress_identifier_warnings/1)
        end)

      {:ok, args}
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

  defp suppress_identifier_warnings({name, meta, context})
       when is_atom(name) and is_atom(context) do
    # Prepend an underscore to suppress warnings
    if not String.starts_with?(Atom.to_string(name), "_") do
      {String.to_atom("_#{name}"), meta, context}
    else
      {name, meta, context}
    end
  end

  defp suppress_identifier_warnings(other) do
    other
  end

  defp pinned_argument?({:^, _meta, context}) when is_list(context) do
    true
  end

  defp pinned_argument?(_other) do
    false
  end
end
