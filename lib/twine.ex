defmodule Twine do
  # Placeholder for ergonomics so iex does not attempt to evaluate the call if one argument is passed
  defmacro print_calls(_dummy) do
    IO.puts(
      "#{IO.ANSI.red()}Invalid call to Twine.print_calls(); expects at least two arguments#{IO.ANSI.reset()}"
    )

    :error
  end

  defmacro print_calls(call, rate, opts \\ []) do
    {m, f, a} = Macro.decompose_call(call)

    quote do
      recon_opts = Keyword.put(unquote(opts), :formatter, &Twine.format/1)

      :recon_trace.calls(
        {unquote(m), unquote(f), fn unquote(a) -> :return_trace end},
        unquote(rate),
        recon_opts
      )
    end
  end

  def format({:trace, pid, :call, {module, function, args}}) do
    f_pid = "#{IO.ANSI.light_red()}#{inspect(pid)}#{IO.ANSI.reset()}"

    # Can't use Atom.to_string(module)/#{module} as that will give the Elixir prefix, which is not great output
    f_module = "#{IO.ANSI.cyan()}#{inspect(module)}#{IO.ANSI.reset()}"
    f_function = "#{IO.ANSI.green()}#{function}#{IO.ANSI.reset()}"

    f_args =
      args
      |> Enum.map(
        &(inspect(&1,
            syntax_colors: IO.ANSI.syntax_colors(),
            pretty: true,
            limit: :infinity,
            printable_limit: :infinity
          )
          |> String.replace("~", "~~"))
      )
      |> Enum.join(", ")

    "[#{DateTime.utc_now()}] #{f_pid} - #{f_module}.#{f_function}(#{f_args})\n"
  end
end
