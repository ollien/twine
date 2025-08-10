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
        System.cmd("iex", ["-S", "mix"], env: [{"IEX_HOME", dir}], stderr_to_stdout: true)

      Regex.replace(~r/^.*BEGIN TWINE TEST\n/s, out, "", global: false)
    end
  end

  def strip_ansi(str) do
    Regex.replace(~r/\x1b\[[0-9;]*m/, str, "")
  end
end

ExUnit.start()
