defmodule Twine do
  @moduledoc """
  Twine is a function call tracer that wraps `recon_trace`.
  """
  alias Twine.Internal

  defmodule TracedCall do
    @doc """
    A call that has been send to the shell via recv_calls. If `ignore_outcome:
    true` was provided, `outcome` will always be nil. Otherwise, it will
    contain the outcome of the traced call. 
    """

    @type t :: %__MODULE__{
            pid: pid(),
            mfa: {module(), atom(), [any()]},
            outcome:
              TracedCallReturned.t() | TracedCallExceptionCaught.t() | TracedCallCrashed.t()
          }

    @enforce_keys [:pid, :mfa]
    defstruct [
      :pid,
      :mfa,
      outcome: nil
    ]
  end

  defmodule TracedCallReturned do
    @type t :: %__MODULE__{
            return_value: term(),
            return_to: {module(), function(), integer()}
          }

    @enforce_keys [:return_value, :return_to]
    defstruct [:return_value, :return_to]
  end

  defmodule TracedCallExceptionCaught do
    @type t :: %__MODULE__{
            exception: term(),
            return_to: {module(), function(), integer()}
          }

    @enforce_keys [:exception, :return_to]
    defstruct [:exception, :return_to]
  end

  defmodule TracedCallCrashed do
    @type t :: %__MODULE__{
            exception: term(),
            exit_reason: term()
          }

    @enforce_keys [:exception, :exit_reason]
    defstruct [:exception, :exit_reason]
  end

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
  print 10 calls per second at most). The calls given can also have patterns
  and/or guards  so you can match specific calls.

  Options:
  - `pid`: the pid to print calls for. If omitted, this will run for all pids
  on the system.
  - `arg_mapper`: A function to map the arguments of the function before
  printing it. This can be useful if you are tracing a call on a function that
  has a very large argument (such as a `GenServer`'s state), and want to reduce
  it down before printing it. This function must have the same arity as the
  captured function, and return a list or tuple of the mapped arguments.
  - `return_mapper`: A function to map the return value of a function before
  printing it. This can be useful if you are tracing a call on a function that
  has a very large return value, and want to reduce it down before printing it.
  This function must have an arity of 1, and return the value directly. If this
  is supplied with `ignore_outcome: true`, it will not be called.
  - `ignore_outcome`: If true, calls are printed immediately, without waiting
  for their return value or a process termination. Defaults to false.
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
