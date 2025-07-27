defmodule Twine do
  @moduledoc """
  Twine is a function call tracer. See README.md for more details
  """
  alias Twine.Internal

  @doc """
  Placeholder for ergonomics so iex does not attempt to evaluate the call if one argument is passed. This has no use.
  """
  defmacro print_calls(_dummy) do
    IO.puts(
      "#{IO.ANSI.red()}Invalid call to Twine.print_calls(); expects at least two arguments#{IO.ANSI.reset()}"
    )

    :error
  end

  @doc """
  Print all calls that match the given function call either the given number of
  times (e.g. 10 will print 10 calls), or at a given rate (e.g. {10, 1000} will
  print 10 calls per second at most). The calls given can also have patterns,
  so you can match specific calls.

  Options:
  - `pid`: the pid to print calls for. If omitted, this will run for all pids
  on the system
  - `mapper`: A function to map the output before printing it. This can be useful
  if you are tracing a call on a function that has a very large argument
  (such as a `GenServer`'s state), and want to reduce it down
  before printing it. This function must have the same arity as
  the captured function, and return a list or tuple of the mapped
  arguments.
  """
  defmacro print_calls(call, rate, opts \\ []) do
    {m, f, a} = Macro.decompose_call(call)

    quote do
      opts = unquote(opts)
      {mapper, opts} = Keyword.pop(opts, :mapper, nil)

      num_args =
        unquote(Macro.escape(a))
        |> Enum.count()

      Internal.validate_mapper!(mapper, num_args)

      recon_opts =
        opts
        |> Keyword.take([:pid])
        |> Keyword.put(:formatter, Internal.make_format_fn(mapper: mapper))
        |> Keyword.put(:scope, :local)

      matches =
        :recon_trace.calls(
          {unquote(m), unquote(f), fn unquote(a) -> :return_trace end},
          unquote(rate),
          recon_opts
        )

      Internal.print_match_output(matches)
    end
  end
end
