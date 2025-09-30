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

  def multiline_call(module, function, args) when is_integer(args) do
    call(module, function, args)
  end

  def multiline_call(module, function, args) do
    f_module = module(module)
    f_function = "#{IO.ANSI.green()}#{function}#{IO.ANSI.reset()}"

    formatted_args = Enum.map(args, &term/1)

    if Enum.any?(formatted_args, fn arg -> String.contains?(arg, "\n") end) do
      f_args =
        formatted_args
        |> Enum.join(",\n")
        |> indented_block(2)

      "#{f_module}.#{f_function}(\n#{f_args}\n)"
    else
      f_args = Enum.join(formatted_args, ", ")
      "#{f_module}.#{f_function}(#{f_args})"
    end
  end

  def indented_block(block, padding_width, opts \\ [])

  def indented_block(text, padding_width, opts) when is_integer(padding_width) do
    padding = String.duplicate(" ", padding_width)
    indented_block(text, padding, opts)
  end

  def indented_block(text, padding, opts) do
    res =
      text
      |> String.trim_leading()
      |> then(fn value ->
        if Keyword.get(opts, :replace_indentation, false) do
          Regex.replace(~r/^\s*/m, value, padding)
        else
          Regex.replace(~r/^(\s*)/m, value, padding <> "\\1")
        end
      end)

    if Keyword.get(opts, :dedent_first_line, false) do
      String.replace_leading(res, padding, "")
    else
      res
    end
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

  def decorated_block(
        color,
        prefix,
        formatted_value,
        pre_decoration_width,
        decoration_char,
        opts \\ []
      ) do
    pre_decoration_padding = String.duplicate(" ", pre_decoration_width)
    decoration = " #{decoration_char} "

    edge_char =
      if Keyword.get(opts, :decorate_edge, false) do
        "│"
      else
        " "
      end

    continuation_padding =
      pre_decoration_padding <>
        " #{edge_char} " <>
        String.duplicate(" ", String.length(prefix) + 2)

    formatted_value =
      indented_block(
        formatted_value,
        continuation_padding,
        replace_indentation: Keyword.get(opts, :replace_indentation, false),
        dedent_first_line: true
      )

    "#{pre_decoration_padding}#{decoration}#{color}#{prefix}#{IO.ANSI.reset()}: #{formatted_value}"
  end

  defp module(module) do
    # Can't use Atom.to_string(module)/#{module} as that will give the Elixir prefix, which is not great output
    "#{IO.ANSI.cyan()}#{inspect(module)}#{IO.ANSI.reset()}"
  end
end
