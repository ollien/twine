defmodule Twine.Internal do
  @moduledoc false
  # This module exists so that the macros can access these functions, but there
  # is absolutely no guarantee around their stability

  def format({:trace, pid, :call, {module, function, args}}) do
    f_pid = "#{IO.ANSI.light_red()}#{inspect(pid)}#{IO.ANSI.reset()}"

    # Can't use Atom.to_string(module)/#{module} as that will give the Elixir prefix, which is not great output
    f_module = "#{IO.ANSI.cyan()}#{inspect(module)}#{IO.ANSI.reset()}"
    f_function = "#{IO.ANSI.green()}#{function}#{IO.ANSI.reset()}"

    f_args =
      args
      |> Enum.map(
        &(inspect(&1,
            syntax_colors: IO.ANSI.syntax_colors(),
            pretty: true,
            limit: :infinity,
            printable_limit: :infinity
          )
          |> String.replace("~", "~~"))
      )
      |> Enum.join(", ")

    "[#{DateTime.utc_now()}] #{f_pid} - #{f_module}.#{f_function}(#{f_args})\n"
  end
end
