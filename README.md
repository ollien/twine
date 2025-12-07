# Twine

[![Hex.pm Version](https://img.shields.io/hexpm/v/twine)](https://hex.pm/packages/twine) [![Hex Docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/twine/twine.html)

Twine is a tracing tool based on Ferd's wonderful [`recon_trace`](https://ferd.github.io/recon/recon_trace.html).

`recon_trace` is great for providing a safe way to debug live BEAM systems,
but can be a little unweildy, especially on Elixir systems. `Twine` is a wrapper
for `recon_trace`, and adds a familiar, friendly, syntax.

## Usage

In a remote shell for your running process,

```ex
require Twine

Twine.print_calls(MyModule.my_function(_arg1, _arg2), 3)
```

Just like `recon_trace`, this will print the first three calls to
`MyModule.my_function/2`, but will do so in Elixir syntax.

You can even match specific calls by using pattern matching. This will
print all calls to `handle_call` for the :ping call.
```ex
require Twine

Twine.print_calls(MyModule.handle_call(:ping, _from, _state), 3)
```

More details are provided in the hex docs.

## Installation

```elixir
def deps do
  [
    {:twine, "~> 0.5.0"}
  ]
end
```

