defmodule Twine do
  alias Twine.Internal

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
      recon_opts =
        unquote(opts)
        |> Keyword.take([:pid])
        |> Keyword.put(:formatter, &Internal.format/1)
        |> Keyword.put(:scope, :local)

      :recon_trace.calls(
        {unquote(m), unquote(f), fn unquote(a) -> :return_trace end},
        unquote(rate),
        recon_opts
      )
    end
  end
end
