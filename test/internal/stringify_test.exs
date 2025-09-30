defmodule Twine.Internal.StringifyTest do
  alias Twine.Internal.Stringify

  use ExUnit.Case

  describe "pid/1" do
    test "displays pid" do
      pid = :erlang.list_to_pid(~c"<0.123.456>")
      assert("\e[91m#PID<0.123.456>\e[0m" == Stringify.pid(pid))
    end
  end

  describe "call/3" do
    test "displays call" do
      assert "\e[36mMyModule\e[0m.\e[32mmy_function\e[0m(\e[36m:foo\e[0m, \e[36m:bar\e[0m, \e[36m:baz\e[0m)" ==
               Stringify.call(MyModule, :my_function, [:foo, :bar, :baz])
    end
  end

  describe "multiline_call/3" do
    test "prints simple calls as single line" do
      assert "\e[36mMyModule\e[0m.\e[32mmy_function\e[0m(\e[36m:foo\e[0m, \e[36m:bar\e[0m, \e[36m:baz\e[0m)" ==
               Stringify.multiline_call(MyModule, :my_function, [:foo, :bar, :baz])
    end

    test "prints calls with multiline terms on multiple lines" do
      assert """
             MyModule.my_function(
               :foo,
               :bar,
               {:this_is_really_long_and_will_wrap, :this_is_really_long_and_will_wrap,
                :this_is_really_long_and_will_wrap, :this_is_really_long_and_will_wrap,
                :this_is_really_long_and_will_wrap, :this_is_really_long_and_will_wrap,
                :this_is_really_long_and_will_wrap}
             )\
             """ ==
               Stringify.multiline_call(MyModule, :my_function, [
                 :foo,
                 :bar,
                 {:this_is_really_long_and_will_wrap, :this_is_really_long_and_will_wrap,
                  :this_is_really_long_and_will_wrap, :this_is_really_long_and_will_wrap,
                  :this_is_really_long_and_will_wrap, :this_is_really_long_and_will_wrap,
                  :this_is_really_long_and_will_wrap}
               ])
               # Strip ANSI so we can more easily see indentation
               |> TestHelper.strip_ansi()
    end
  end

  describe "decorated_block/3" do
    test "only displays on one line if the decoration has no newlines" do
      assert " ├ \e[36mEntry\e[0m: This is a value" ==
               Stringify.decorated_block(
                 IO.ANSI.cyan(),
                 "Entry",
                 "This is a value",
                 0,
                 "├"
               )
    end

    test "preserves indentation on subsequent lines" do
      assert """
                          ├ Entry: This is a value
                                   This is another value\
             """ ==
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
      assert """
                  ├ Entry: This is a value
                  │        This is another value\
             """ ==
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
      assert """
                  ├ Entry: This is a value
                  │        This is another value
                  │          This is yet another value\
             """ ==
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
      assert """
                  ├ Entry: This is a value
                           This is another value
                           This is yet another value\
             """ ==
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
      assert """
                  ├ Entry: This is a value
                  │        This is another value
                  │        This is yet another value\
             """ ==
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

  describe "indented_block/2" do
    test "indents a block with the given number of spaces" do
      assert """
                 foo
                 bar\
             """ == Stringify.indented_block("foo\nbar", 4)
    end

    test "indents a block with the given prefix" do
      assert """
             ----foo
             ----bar\
             """ == Stringify.indented_block("foo\nbar", "----")
    end

    test "preserves indentation of any given line" do
      assert """
                 foo
                   bar\
             """ == Stringify.indented_block("foo\n  bar", 4)
    end

    test "replaces indentation if replace_indentation: true is provided" do
      assert """
                 foo
                 bar\
             """ == Stringify.indented_block("foo\n  bar", 4, replace_indentation: true)
    end

    test "doesn't indent first line if dedent_first_line: true is provided" do
      assert """
             foo
                 bar
                 baz\
             """ == Stringify.indented_block("foo\nbar\nbaz", 4, dedent_first_line: true)
    end
  end
end
