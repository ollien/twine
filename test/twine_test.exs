# These tests are annoyingly complicated in the way they're structured.
#
# 1. The top-level macros of Twine are nigh identical, just in how they
#    generate output, so we have this TraceMacroCase CaseTemplate that we
#    use to generate test cases for each macro. Each template takes the name
#    of the macro and a quoted AST block on how to generate output.
# 2. Each test has to run under iex, so we run blocks of code in this `iex_run`
#    macro. Check TestHelper to see how it works
defmodule TraceMacroCase do
  use ExUnit.CaseTemplate

  using(opts) do
    macro_name = Keyword.fetch!(opts, :macro_name)
    generate_output = Keyword.fetch!(opts, :generate_output)

    quote do
      require TestHelper

      test "prints invocations to remote function" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1)
            Blah.func(1, 2, 3)

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        refute TestHelper.has_exception?(output)
      end

      test "prints invocations to local function" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end

              def doit() do
                func(1, 2, 3)
              end
            end

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1)
            Blah.doit()

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        refute TestHelper.has_exception?(output)
      end

      test "allows matching patterns in the trace" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end

              def doit() do
                func(1, 2, 3)
              end
            end

            Twine.unquote(macro_name)(Blah.func(1, _b, _c), 1)
            Blah.doit()

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        refute TestHelper.has_exception?(output)
      end

      test "allows matching guards in the trace" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end

              def doit() do
                func(1, 2, 3)
              end
            end

            Twine.unquote(macro_name)(Blah.func(a, _b, _c) when is_integer(a), 1)
            Blah.doit()

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        refute TestHelper.has_exception?(output)
      end

      test "does not print anything if the pattern does not match" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end

              def doit() do
                func(1, 2, 3)
              end
            end

            Twine.unquote(macro_name)(Blah.func(0, 0, 0), 1)
            Blah.doit()

            Code.eval_quoted(unquote(generate_output))
          end

        refute TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        refute TestHelper.has_exception?(output)
      end

      test "does not print anything if the guard does not match" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end

              def doit() do
                func(1, 2, 3)
              end
            end

            Twine.unquote(macro_name)(Blah.func(a, _b, _c) when is_nil(a), 1)
            Blah.doit()

            Code.eval_quoted(unquote(generate_output))
          end

        refute TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        refute TestHelper.has_exception?(output)
      end

      test "allows capturing of single pids" do
        output =
          TestHelper.iex_run do
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

            Twine.unquote(macro_name)(Blah.func(_arg1, _arg2, _arg3), 2, pid: pid)
            Blah.func(1, 2, 3)
            send(pid, :begin)

            Blah.func(0, 0, 0)

            receive do
              :done -> :ok
            end

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        refute TestHelper.strip_ansi(output) =~ "Blah.func(0, 0, 0)"
        refute TestHelper.has_exception?(output)
      end

      test "allows mapping of args" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(Blah.func(_arg1, _arg2, _arg3), 1,
              mapper: fn a, b, c ->
                [a * 1, b * 2, c * 3]
              end
            )

            Blah.func(1, 2, 3)

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 4, 9)"
        refute TestHelper.has_exception?(output)
      end

      test "allows mapping of args with tuple return value" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(Blah.func(_arg1, _arg2, _arg3), 1,
              mapper: fn a, b, c ->
                {a * 1, b * 2, c * 3}
              end
            )

            Blah.func(1, 2, 3)

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 4, 9)"
        refute TestHelper.has_exception?(output)
      end

      test "cannot pass a mapper of incorrect arity" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(
              Blah.func(_arg1, _arg2, _arg3),
              1,
              mapper: fn a ->
                {a}
              end
            )
          end

        assert TestHelper.strip_ansi(output) =~
                 "Mapper function must have the same arity as traced function"

        refute TestHelper.has_exception?(output)
      end

      test "informs user if call is missing" do
        output =
          TestHelper.iex_run do
            require Twine

            Twine.unquote(macro_name)(Blah.func(), 1)
            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~
                 "No functions matched, check that it is specified correctly"

        refute TestHelper.has_exception?(output)
      end

      test "informs user call is matched" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(Blah.func(_arg1, _arg2, _arg3), 1)
          end

        assert TestHelper.strip_ansi(output) =~ "1 function(s) matched, waiting for calls..."
        refute TestHelper.has_exception?(output)
      end

      test "does not emit warnings for non-underscore prefixed names" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(Blah.func(arg1, _arg2, _arg3), 1)
          end

        refute TestHelper.strip_ansi(output) =~ "warning: variable \"arg1\" is unused"
        refute TestHelper.has_exception?(output)
      end

      test "does not emit warnings for non-underscore prefixed names even in structures" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(Blah.func({a, [b, c], %{"key" => [e, f]}}, _arg2, _arg3), 1)
          end

        refute TestHelper.strip_ansi(output) =~ "warning: variable \"a\" is unused"
        refute TestHelper.has_exception?(output)
        refute TestHelper.strip_ansi(output) =~ "warning: variable \"b\" is unused"
        refute TestHelper.strip_ansi(output) =~ "warning: variable \"c\" is unused"
        refute TestHelper.strip_ansi(output) =~ "warning: variable \"d\" is unused"
        refute TestHelper.strip_ansi(output) =~ "warning: variable \"e\" is unused"
        refute TestHelper.strip_ansi(output) =~ "warning: variable \"f\" is unused"
        refute TestHelper.has_exception?(output)
      end

      test "does not emit warnings for names being used in guards" do
        # Covers the case of there being an intersection of variables in guards
        # and args. The naive approach resulted in warnings from trying to reuse
        # the "suppressed" variables
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(
              Blah.func(arg1, arg2, _arg3) when is_integer(arg1) and not is_nil(arg2),
              1
            )
          end

        refute TestHelper.strip_ansi(output) =~
                 "The underscored variable \"_arg1\" is used after being set."

        refute TestHelper.has_exception?(output)
      end

      test "cannot pass call with pinned variable" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            x = 5

            Twine.unquote(macro_name)(
              Blah.func(^x, _arg2, _arg3),
              1,
              mapper: fn a ->
                {a}
              end
            )
          end

        assert TestHelper.strip_ansi(output) =~
                 "Call cannot contain a pattern that uses the pin operator (^)"

        refute TestHelper.has_exception?(output)
      end

      test "cannot pass guard with variables not in argument patterns" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            x = 5
            y = 6

            Twine.unquote(macro_name)(
              Blah.func(z, _arg2, _arg3) when y == x or y == z,
              1,
              mapper: fn a ->
                {a}
              end
            )
          end

        assert TestHelper.strip_ansi(output) =~
                 "Identifiers in guard must exist in argument pattern. Invalid identifiers: x, y"

        refute TestHelper.has_exception?(output)
      end

      test "calling clear stops tracing" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1)
            Twine.clear()
            Blah.func(1, 2, 3)

            Code.eval_quoted(unquote(generate_output))
          end

        refute TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        refute TestHelper.has_exception?(output)
      end

      # This covers a specific case where the :return_from case is not handled
      # and recon_trace throws an error in another process
      test "allows selecting more than one response without crashing" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 2)
            Blah.func(1, 2, 3)

            Code.eval_quoted(unquote(generate_output))
          end

        refute TestHelper.has_exception?(output)
      end
    end
  end
end

defmodule Twine.PrintCallsTest do
  use TraceMacroCase,
    macro_name: :print_calls,
    generate_output:
      (quote do
         # Give recon_trace some time to print the call before IEx exits
         Process.sleep(100)
       end)
end

defmodule Twine.RecvCallsTest do
  use TraceMacroCase,
    macro_name: :recv_calls,
    # We can't use recursion in this macro expansion, so we cheat a little bit by using
    # Stream.repeatedly and Enum.reduce_while
    generate_output:
      (quote do
         Stream.repeatedly(fn -> nil end)
         |> Enum.reduce_while(nil, fn nil, nil ->
           receive do
             {pid, {m, f, a}} when is_pid(pid) ->
               IO.inspect("#{m}.#{f}(#{Enum.join(a, ", ")})")
               {:cont, nil}
           after
             100 -> {:halt, nil}
           end
         end)
       end)
end
