defmodule Twine.Internal.StringifyTest do
  alias Twine.Internal.Stringify

  use ExUnit.Case
  use Mneme

  describe "pid/1" do
    test "displays pid" do
      pid = :erlang.list_to_pid(~c"<0.123.456>")
      auto_assert("\e[91m#PID<0.123.456>\e[0m" <- Stringify.pid(pid))
    end
  end

  describe "call/3" do
    test "displays call" do
      auto_assert "\e[36mMyModule\e[0m.\e[32mmy_function\e[0m(\e[36m:foo\e[0m, \e[36m:bar\e[0m, \e[36m:baz\e[0m)" <-
                    Stringify.call(MyModule, :my_function, [:foo, :bar, :baz])
    end
  end

  describe "decorated_block/3" do
    test "only displays on one line if the decoration has no newlines" do
      auto_assert " ├ \e[36mEntry\e[0m: This is a value" <-
                    Stringify.decorated_block(
                      IO.ANSI.cyan(),
                      "Entry",
                      "This is a value",
                      0,
                      "├"
                    )
    end

    test "preserves indentation on subsequent lines" do
      auto_assert """
                               ├ Entry: This is a value
                                        This is another value\
                  """ <-
                    Stringify.decorated_block(
                      IO.ANSI.cyan(),
                      "Entry",
                      "This is a value\nThis is another value",
                      12,
                      "├"
                    )
                    # Strip ANSI so we can more easily see indentation
                    |> TestHelper.strip_ansi()
    end

    test "extends decoration using box drawing chars when decorate_edge: true is specified" do
      auto_assert """
                       ├ Entry: This is a value
                       │        This is another value\
                  """ <-
                    Stringify.decorated_block(
                      IO.ANSI.cyan(),
                      "Entry",
                      "This is a value\nThis is another value",
                      4,
                      "├",
                      decorate_edge: true
                    )
                    # Strip ANSI so we can more easily see indentation
                    |> TestHelper.strip_ansi()
    end

    test "preserves indentation within a line" do
      auto_assert """
                       ├ Entry: This is a value
                       │        This is another value
                       │          This is yet another value\
                  """ <-
                    Stringify.decorated_block(
                      IO.ANSI.cyan(),
                      "Entry",
                      "This is a value\nThis is another value\n  This is yet another value",
                      4,
                      "├",
                      decorate_edge: true
                    )
                    # Strip ANSI so we can more easily see indentation
                    |> TestHelper.strip_ansi()
    end

    test "replaces indentation when requested with replace_indentation: true" do
      auto_assert """
                       ├ Entry: This is a value
                                This is another value
                                This is yet another value\
                  """ <-
                    Stringify.decorated_block(
                      IO.ANSI.cyan(),
                      "Entry",
                      "This is a value\nThis is another value\n  This is yet another value",
                      4,
                      "├",
                      replace_indentation: true
                    )
                    # Strip ANSI so we can more easily see indentation
                    |> TestHelper.strip_ansi()
    end

    test "can combine replace_indentation with decorate_edge" do
      auto_assert """
                       ├ Entry: This is a value
                       │        This is another value
                       │        This is yet another value\
                  """ <-
                    Stringify.decorated_block(
                      IO.ANSI.cyan(),
                      "Entry",
                      "This is a value\nThis is another value\n  This is yet another value",
                      4,
                      "├",
                      decorate_edge: true,
                      replace_indentation: true
                    )
                    # Strip ANSI so we can more easily see indentation
                    |> TestHelper.strip_ansi()
    end
  end
end
