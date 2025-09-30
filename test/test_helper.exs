defmodule TestHelper do
  # This is incredibly hacky. :recon_trace does not allow us to actually use
  # calls unless the function passed to it is defined in a shell... so we
  # shell out to iex.
  #
  # That isn't so bad on its face. Here's the big stinky: we can't pipe input
  # into iex, so we:
  #
  # 1) Place the file .iex.exs in a temp directory - this file acts as if
  #    we typed the given text into iex (https://hexdocs.pm/iex/IEx.html#module-the-iex-exs-file)
  #
  # 2) Tell the command to use an IEX_HOME to consider this file a "global"
  #    .iex.exs file.
  #
  # 3) Within .iex.exs, use Code.eval_string to ensure that failures to compile
  #    do not result in the test completely hanging.
  defmacro iex_run(do: block) do
    quote do
      # Base64 encode so we can insert it into the string without collision
      encoded_code = Base.encode64(unquote(Macro.to_string(block)))

      code = """
        IO.puts("BEGIN TWINE TEST")
        {:ok, code} = Base.decode64("#{encoded_code}")
        try do
          Code.eval_string(code)
        catch
          exc, reason -> 
            IO.inspect({exc, reason}, label: "code threw error")
            System.halt(1)
        end

        System.halt(0)
      """

      Temp.track!()
      dir = Temp.mkdir!()
      iex_file_path = Path.join(dir, ".iex.exs")
      File.write!(iex_file_path, code)

      {out, 0} =
        System.cmd("iex", ["-S", "mix"],
          # Run in test mode so we can reuse the already compiled artifact in async tests
          env: [{"IEX_HOME", dir}, {"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      Regex.replace(~r/^.*BEGIN TWINE TEST\n/s, out, "", global: false)
    end
  end

  def strip_ansi(str) do
    Regex.replace(~r/\x1b\[[0-9;]*m/, str, "")
  end

  def has_exception?(output) do
    output =~ "raised an exception"
  end

  def generate_print_output_ast() do
    quote do
      # Give recon_trace some time to print the call before IEx exits
      Process.sleep(250)
    end
  end

  def generate_tracked_recv_output_ast() do
    # We can't use recursion in this macro expansion, so we cheat a little bit by using
    # Stream.repeatedly and Enum.reduce_while
    quote do
      Stream.repeatedly(fn -> nil end)
      |> Enum.reduce_while(nil, fn nil, nil ->
        receive do
          %Twine.TracedCall{pid: pid, mfa: {m, f, a}, outcome: outcome} when is_pid(pid) ->
            IO.puts("#{inspect(m)}.#{f}(#{Enum.join(a, ", ")})")

            case outcome do
              %Twine.TracedCallReturned{
                return_value: return_value,
                return_to: {return_m, return_f, return_a}
              } ->
                IO.puts("Returned: #{inspect(return_value)}")
                IO.inspect("Returned to: #{inspect(return_m)}.#{return_f}/#{return_a}")

              %Twine.TracedCallExceptionCaught{
                exception: exception,
                return_to: {return_m, return_f, return_a}
              } ->
                IO.puts("Raised Exception: #{inspect(exception)}")
                IO.puts("Returned to: #{inspect(return_m)}.#{return_f}/#{return_a}")

              %Twine.TracedCallCrashed{
                exception: exception,
                exit_reason: {_error, stack}
              } ->
                IO.puts("Raised Exception: #{inspect(exception)}")

                IO.puts(
                  "Process Terminated: #{stack |> Exception.format_stacktrace() |> String.trim_leading()}"
                )

              %Twine.TracedCallCrashed{
                exception: exception,
                exit_reason: reason
              } ->
                IO.puts("Raised Exception: #{inspect(exception)}")
                IO.puts("Process Terminated: #{inspect(reason)}")
            end

            {:cont, nil}
        after
          250 -> {:halt, nil}
        end
      end)
    end
  end

  def generate_simple_recv_output_ast() do
    # We can't use recursion in this macro expansion, so we cheat a little bit by using
    # Stream.repeatedly and Enum.reduce_while
    quote do
      Stream.repeatedly(fn -> nil end)
      |> Enum.reduce_while(nil, fn nil, nil ->
        receive do
          %Twine.TracedCall{pid: pid, mfa: {m, f, a}, outcome: nil} when is_pid(pid) ->
            IO.puts("#{inspect(m)}.#{f}(#{Enum.join(a, ", ")})")

            {:cont, nil}
        after
          250 -> {:halt, nil}
        end
      end)
    end
  end
end

ExUnit.start()
