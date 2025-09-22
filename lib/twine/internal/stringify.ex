defmodule Twine.Internal.Stringify do
  @moduledoc false
  # This module exists for convenience functions in Internal,
  # there is is absolutely no guarantee around its stability

  def pid(pid) when is_pid(pid) do
    "#{IO.ANSI.light_red()}#{inspect(pid)}#{IO.ANSI.reset()}"
  end

  def call(module, function, args) when is_integer(args) do
    f_module = module(module)
    f_function = "#{IO.ANSI.green()}#{function}#{IO.ANSI.reset()}"
    f_args = "#{IO.ANSI.yellow()}#{args}#{IO.ANSI.reset()}"

    "#{f_module}.#{f_function}/#{f_args}"
  end

  def call(module, function, args) do
    f_module = module(module)
    f_function = "#{IO.ANSI.green()}#{function}#{IO.ANSI.reset()}"

    f_args =
      args
      |> Enum.map(&term/1)
      |> Enum.join(", ")

    "#{f_module}.#{f_function}(#{f_args})"
  end

  def term(term) do
    inspect(
      term,
      syntax_colors: IO.ANSI.syntax_colors(),
      pretty: true,
      limit: :infinity,
      printable_limit: :infinity
    )
  end

  defp module(module) do
    # Can't use Atom.to_string(module)/#{module} as that will give the Elixir prefix, which is not great output
    "#{IO.ANSI.cyan()}#{inspect(module)}#{IO.ANSI.reset()}"
  end
end
