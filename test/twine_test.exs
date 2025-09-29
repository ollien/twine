# These tests are annoyingly complicated in the way they're structured.
#
# 1. The top-level macros of Twine are nigh identical, just in how they
#    generate output, so we have two CaseTemplates that we
#    use to generate test cases for each macro. Each template takes the name
#    of the macro and a quoted AST block on how to generate output.
# 2. Each test has to run under iex, so we run blocks of code in this `iex_run`
#    macro. Check TestHelper to see how it works
defmodule Twine.TraceMacroCase do
  use ExUnit.CaseTemplate

  using(opts) do
    macro_name = Keyword.fetch!(opts, :macro_name)
    {generate_output, []} = Code.eval_quoted(Keyword.fetch!(opts, :generate_output))
    base_opts = Keyword.fetch!(opts, :base_opts)

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

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1, unquote(base_opts))
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

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1, unquote(base_opts))
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

            Twine.unquote(macro_name)(Blah.func(1, _b, _c), 1, unquote(base_opts))
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

            Twine.unquote(macro_name)(
              Blah.func(a, _b, _c) when is_integer(a),
              1,
              unquote(base_opts)
            )

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

            Twine.unquote(macro_name)(Blah.func(0, 0, 0), 1, unquote(base_opts))
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

            Twine.unquote(macro_name)(Blah.func(a, _b, _c) when is_nil(a), 1, unquote(base_opts))
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

            Twine.unquote(macro_name)(
              Blah.func(_arg1, _arg2, _arg3),
              2,
              [pid: pid] ++ unquote(base_opts)
            )

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

            Twine.unquote(macro_name)(
              Blah.func(_arg1, _arg2, _arg3),
              1,
              [
                arg_mapper: fn a, b, c ->
                  [a * 1, b * 2, c * 3]
                end
              ] ++
                unquote(base_opts)
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

            Twine.unquote(macro_name)(
              Blah.func(_arg1, _arg2, _arg3),
              1,
              [
                arg_mapper: fn a, b, c ->
                  {a * 1, b * 2, c * 3}
                end
              ] ++
                unquote(base_opts)
            )

            Blah.func(1, 2, 3)

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 4, 9)"
        refute TestHelper.has_exception?(output)
      end

      test "cannot pass an args mapper of incorrect arity" do
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
              [
                arg_mapper: fn a ->
                  {a}
                end
              ] ++ unquote(base_opts)
            )
          end

        assert TestHelper.strip_ansi(output) =~
                 "Argument mapper function must have the same arity as traced function"

        refute TestHelper.has_exception?(output)
      end

      test "informs user if call is missing" do
        output =
          TestHelper.iex_run do
            require Twine

            Twine.unquote(macro_name)(Blah.func(), 1, unquote(base_opts))
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

            Twine.unquote(macro_name)(Blah.func(_arg1, _arg2, _arg3), 1, unquote(base_opts))
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

            Twine.unquote(macro_name)(Blah.func(arg1, _arg2, _arg3), 1, unquote(base_opts))
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

            Twine.unquote(macro_name)(
              Blah.func({a, [b, c], %{"key" => [e, f]}}, _arg2, _arg3),
              1,
              unquote(base_opts)
            )
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
              1,
              unquote(base_opts)
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
              [
                arg_mapper: fn a ->
                  {a}
                end
              ] ++ unquote(base_opts)
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
              [
                arg_mapper: fn a ->
                  {a}
                end
              ] ++ unquote(base_opts)
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

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1, unquote(base_opts))
            Twine.clear()
            Blah.func(1, 2, 3)

            Code.eval_quoted(unquote(generate_output))
          end

        refute TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        refute TestHelper.has_exception?(output)
      end

      test "produces the exact number of calls" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end
            end

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 10, unquote(base_opts))

            Enum.each(1..15, fn _n ->
              Blah.func(1, 2, 3)
              Code.eval_quoted(unquote(generate_output))
            end)
          end

        refute TestHelper.has_exception?(output)

        num_calls =
          output
          |> TestHelper.strip_ansi()
          # Amazingly, this is the most concise way to count occurrences
          |> String.split("Blah.func(1, 2, 3)")
          |> Enum.count()
          |> then(fn n -> n - 1 end)

        assert num_calls == 10
      end
    end
  end
end

defmodule Twine.TrackedOnlyTraceMacroCase do
  use ExUnit.CaseTemplate

  using(opts) do
    macro_name = Keyword.fetch!(opts, :macro_name)
    {generate_output, []} = Code.eval_quoted(Keyword.fetch!(opts, :generate_output))

    quote do
      require TestHelper

      test "prints return function and return value" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                nil
              end

              def doit() do
                # Can't be in the tail position, or we don't show the right return_to
                func(1, 2, 3)

                :ok
              end
            end

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1)
            Blah.doit()

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        assert TestHelper.strip_ansi(output) =~ "Returned: nil"
        assert TestHelper.strip_ansi(output) =~ "Returned to: Blah.doit/0"
        refute TestHelper.has_exception?(output)
      end

      test "prints return function and exception when caught" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                raise "oh no"
              end

              def doit() do
                # Can't be in the tail position, or we don't show the right return_to
                try do
                  func(1, 2, 3)
                rescue
                  error -> {:error, :caught, error}
                end

                :ok
              end
            end

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1)
            Blah.doit()

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"

        assert TestHelper.strip_ansi(output) =~
                 "Raised Exception: {:error, %RuntimeError{message: \"oh no\"}}"

        assert TestHelper.strip_ansi(output) =~ "Returned to: Blah.doit/0"
        refute TestHelper.has_exception?(output)
      end

      test "prints exception and stack information when a process crashes" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                raise "oh no"
              end

              def doit() do
                Blah.func(1, 2, 3)
              end
            end

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1)

            spawn(fn ->
              Blah.doit()
            end)

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"

        assert TestHelper.strip_ansi(output) =~
                 "Raised Exception: {:error, %RuntimeError{message: \"oh no\"}}"

        assert TestHelper.strip_ansi(output) =~ "Process Terminated: nofile:5: Blah.func/3"
        # does not check for an exception, since we explicitly are throwing one
      end

      test "can remap return value" do
        output =
          TestHelper.iex_run do
            require Twine

            defmodule Blah do
              def func(_argument1, _argument2, _argument3) do
                "hello"
              end
            end

            Twine.unquote(macro_name)(Blah.func(_a, _b, _c), 1, return_mapper: &String.upcase/1)
            Blah.func(1, 2, 3)

            Code.eval_quoted(unquote(generate_output))
          end

        assert TestHelper.strip_ansi(output) =~ "Blah.func(1, 2, 3)"
        assert TestHelper.strip_ansi(output) =~ "Returned: \"HELLO\""
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
              return_mapper: fn a, b -> nil end
            )
          end

        assert TestHelper.strip_ansi(output) =~
                 "Return mapper function must have an arity of 1"

        refute TestHelper.has_exception?(output)
      end
    end
  end
end

defmodule Twine.PrintCallsTestTracked do
  use Twine.TraceMacroCase,
    async: true,
    macro_name: :print_calls,
    base_opts: [],
    generate_output: TestHelper.generate_print_output_ast()
end

defmodule Twine.PrintCallsTestSimple do
  use Twine.TraceMacroCase,
    async: true,
    macro_name: :print_calls,
    base_opts: [ignore_outcome: true],
    generate_output: TestHelper.generate_print_output_ast()
end

defmodule Twine.TrackedOnlyPrintCallsTest do
  use Twine.TrackedOnlyTraceMacroCase,
    async: true,
    macro_name: :print_calls,
    generate_output: TestHelper.generate_print_output_ast()
end

defmodule Twine.RecvCallsTestTracked do
  use Twine.TraceMacroCase,
    async: true,
    macro_name: :recv_calls,
    base_opts: [],
    generate_output: TestHelper.generate_tracked_recv_output_ast()
end

defmodule Twine.RecvCallsTestSimple do
  use Twine.TraceMacroCase,
    async: true,
    macro_name: :recv_calls,
    base_opts: [ignore_outcome: true],
    generate_output: TestHelper.generate_simple_recv_output_ast()
end

defmodule Twine.TrackedOnlyRecvCallsTest do
  use Twine.TrackedOnlyTraceMacroCase,
    async: true,
    macro_name: :recv_calls,
    generate_output: TestHelper.generate_tracked_recv_output_ast()
end
