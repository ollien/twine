defmodule Twine do
  @moduledoc """
  Twine is a function call tracer that wraps `recon_trace`.
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
  - `mapper`: A function to map the output before printing it. This can be 
  useful if you are tracing a call on a function that has a very large argument
  (such as a `GenServer`'s state), and want to reduce it down
  before printing it. This function must have the same arity as
  the captured function, and return a list or tuple of the mapped
  arguments.
  """
  defmacro print_calls(call, rate, opts \\ []) do
    Internal.run(call, fn matchspec_ast, num_args ->
      quote do
        Internal.do_print_calls(
          unquote(matchspec_ast),
          unquote(num_args),
          unquote(rate),
          unquote(opts)
        )
      end
    end)
  end

  @doc """
  Identical to `print_calls/2`, but instead of printing the calls, it sends
  them to the calling process. This will be of the form
  `{pid, {module, function, arguments}}`.
  """
  defmacro recv_calls(call, rate, opts \\ []) do
    Internal.run(call, fn matchspec_ast, num_args ->
      quote do
        Internal.do_recv_calls(
          unquote(matchspec_ast),
          unquote(num_args),
          unquote(rate),
          unquote(opts)
        )
      end
    end)
  end

  @doc """
  Clear all existing traces.
  """
  def clear() do
    :recon_trace.clear()
  end
end
