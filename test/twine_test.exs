defmodule TwineTest do
  use ExUnit.Case

  require Twine

  doctest Twine

  # This is incredibly hacky. :reocn_trace does not allow us to actually use
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
  # 3) Within iex.exs, use Code.eval_string to ensure that failures to compile
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
        System.cmd("iex", ["-S", "mix"], env: [{"IEX_HOME", dir}], stderr_to_stdout: true)

      Regex.replace(~r/^.*BEGIN TWINE TEST\n/s, out, "", global: false)
    end
  end

  defp strip_ansii(str) do
    Regex.replace(~r/\x1b\[[0-9;]*m/, str, "")
  end

  describe "print_calls" do
    test "prints invocations to remote function" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end
          end

          Twine.print_calls(Blah.func(_a, _b, _c), 1)
          Blah.func(1, 2, 3)

          # Give recon_trace some time to run
          Process.sleep(100)
        end

      assert strip_ansii(output) =~ "Blah.func(1, 2, 3)"
    end

    test "prints invocations to local function" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end

            def doit() do
              func(1, 2, 3)
            end
          end

          Twine.print_calls(Blah.func(_a, _b, _c), 1)
          Blah.doit()

          # Give recon_trace some time to run
          Process.sleep(100)
        end

      assert strip_ansii(output) =~ "Blah.func(1, 2, 3)"
    end

    test "allows matching patterns in the trace" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end

            def doit() do
              func(1, 2, 3)
            end
          end

          Twine.print_calls(Blah.func(1, _b, _c), 1)
          Blah.doit()

          # Give recon_trace some time to run
          Process.sleep(100)
        end

      assert strip_ansii(output) =~ "Blah.func(1, 2, 3)"
    end

    test "does not print anything if the pattern does not match" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end

            def doit() do
              func(1, 2, 3)
            end
          end

          Twine.print_calls(Blah.func(0, 0, 0), 1)
          Blah.doit()

          # Give recon_trace some time to run
          Process.sleep(100)
        end

      refute strip_ansii(output) =~ "Blah.func(1, 2, 3)"
    end

    test "allows capturing of single pids" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end
          end

          parent = self()

          pid =
            spawn(fn ->
              receive do
                :begin -> :ok
              end

              Blah.func(1, 2, 3)
              send(parent, :done)
            end)

          Twine.print_calls(Blah.func(_arg1, _arg2, _arg3), 2, pid: pid)
          send(pid, :begin)

          Blah.func(0, 0, 0)

          receive do
            :done -> :ok
          end

          # Give recon_trace some time to run
          Process.sleep(100)
        end

      assert strip_ansii(output) =~ "Blah.func(1, 2, 3)"
      refute strip_ansii(output) =~ "Blah.func(0, 0, 0)"
    end

    test "allows mapping of args" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end
          end

          Twine.print_calls(Blah.func(_arg1, _arg2, _arg3), 1,
            mapper: fn a, b, c ->
              [a * 1, b * 2, c * 3]
            end
          )

          Blah.func(1, 2, 3)

          # Give recon_trace some time to run
          Process.sleep(100)
        end

      assert strip_ansii(output) =~ "Blah.func(1, 4, 9)"
    end

    test "allows mapping of args with tuple return value" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end
          end

          Twine.print_calls(Blah.func(_arg1, _arg2, _arg3), 1,
            mapper: fn a, b, c ->
              {a * 1, b * 2, c * 3}
            end
          )

          Blah.func(1, 2, 3)

          # Give recon_trace some time to run
          Process.sleep(100)
        end

      assert strip_ansii(output) =~ "Blah.func(1, 4, 9)"
    end

    test "cannot pass a mapper of incorrect arity" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end
          end

          Twine.print_calls(
            Blah.func(_arg1, _arg2, _arg3),
            1,
            mapper: fn a ->
              {a}
            end
          )
        end

      assert strip_ansii(output) =~ "Mapper function must have the same arity as traced function"
    end

    test "informs user if call is missing" do
      output =
        iex_run do
          require Twine

          Twine.print_calls(Blah.func(), 1)
        end

      assert strip_ansii(output) =~ "No functions matched, check that it is specified correctly"
    end

    test "informs user call is matched" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end
          end

          Twine.print_calls(Blah.func(_arg1, _arg2, _arg3), 1)
        end

      assert strip_ansii(output) =~ "1 function(s) matched, waiting for calls..."
    end

    test "does not emit warnings for non-underscore prefixed names" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end
          end

          Twine.print_calls(Blah.func(arg1, _arg2, _arg3), 1)
        end

      refute strip_ansii(output) =~ "warning: variable \"arg1\" is unused"
    end

    test "does not emit warnings for non-underscore prefixed names even instructures" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end
          end

          Twine.print_calls(Blah.func({a, [b, c], %{"key" => [e, f]}}, _arg2, _arg3), 1)
        end

      refute strip_ansii(output) =~ "warning: variable \"a\" is unused"
      refute strip_ansii(output) =~ "warning: variable \"b\" is unused"
      refute strip_ansii(output) =~ "warning: variable \"c\" is unused"
      refute strip_ansii(output) =~ "warning: variable \"d\" is unused"
      refute strip_ansii(output) =~ "warning: variable \"e\" is unused"
      refute strip_ansii(output) =~ "warning: variable \"f\" is unused"
    end
  end

  describe "clear" do
    test "calling clear stops tracing" do
      output =
        iex_run do
          require Twine

          defmodule Blah do
            def func(_argument1, _argument2, _argument3) do
              nil
            end
          end

          Twine.print_calls(Blah.func(_a, _b, _c), 1)
          Twine.clear()
          Blah.func(1, 2, 3)

          # Give recon_trace some time to run
          Process.sleep(100)
        end

      refute strip_ansii(output) =~ "Blah.func(1, 2, 3)"
    end
  end
end
