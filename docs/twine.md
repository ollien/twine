# Twine

Twine allows you to safely introspect calls on a running Elixir system. Under
the hood, it wraps
[`recon_trace`](https://ferd.github.io/recon/recon_trace.html), a battle-tested
library by the venerable Ferd, with some adaptations to make it more useful for
Elixir systems by providing better ergonomics and Elixir-flavored output.

## Background
Out of the box, Erlang provides
[facilities](https://www.erlang.org/doc/apps/erts/erlang.html#trace_pattern/2)
to trace pids. Used improperly, however, you can log far too much information
and kill a node quickly. `recon_trace` solves this by adding protections against
dumping many function calls, but it is built for Erlang first and foremost.
Twine was born out of a desire for a more modern equivalent, but without wanting
to reinvent the wheel.

## Usage
To use Twine, you'll need to connect to a running Elixir node. Typically this is
done by running either 
- `rel/my_app/bin/my_app remote` if you have generated a `mix` release.
- `iex --sname $(openssl rand -hex 8) --remsh my_app@hostname` if you have
  `iex` available on the node.


Once in the shell, you must `require Twine` in order to use its macros. You have
two options to trace calls

 - `Twine.print_calls/2`, which will print calls to the group leader. This is 
   typically what you want if you just want to see what is being called and 
   with what arguments.
 - `Twine.recv_calls/2`, which will send calls to the iex shell's process. These
 messages will be of the type `Twine.TracedCall`, This can
 be useful if you need to have programmatic access to the call data once it has
 been performed. 

The examples below focus primarily on `Twine.print_calls/2`, but the two have 
an identical set of arguments and are thus interchangeable.

When specifying a function to trace, you must provide the function to trace and
a limit on the number of calls to trace. The function can be specified using
either call syntax like `MyServer.handle_call(value, from, state)` or function
capture syntax like `&MyServer.handle_call/3`. These are equivalent for simple
tracing, but call syntax enables pattern matching and guards for more selective
filtering (see examples below).

The limit can be specified in one of two ways:

- An absolute number of calls. For instance,
`Twine.print_calls(MyServer.handle_call(value, from, state), 2)`
  will print the next two invocations of `MyServer.handle_call/3`.
- A maximum rate of calls. For instance,
`Twine.print_calls(MyServer.handle_cast(value, state), {10, 1000})`
  will print up to 10 invocations of `MyServer.handle_cast/2` messages per 1000
ms.

These limits are meant to protect you and your node, so you should not attempt
to bypass the limits by specifying large values like `9999` or `{1000, 1}`.
Doing so will negate many of the safety benefits, and can lead to a node crash.
Typically, I have found that I only need to print out a handful (one to five) of
traces to understand what is happening.

If you choose to combine a rate with `recv_calls`, **you should be careful not
to let these pile up in the process mailbox, or you can consume unbounded
amounts of memory.**

By default, Twine will print that the call itself occurred, and not information
about its outcome (return values, thrown/caught exceptions, and process
crashes/termination). If you would like to display these outcomes
`show_outcome: true` to `print_calls`/`recv_calls`. In order to do this,
Twine must wait for the function to produce an outcome, so be aware that your
calls may not show instantaneously. Twine will also incur a memory penalty, as
it must keep a copy of your function arguments.


### Tracing All Calls To A Function


If you want to view all instances a function is called, you can typically use
`Twine.print_calls` without any options. For instance, the following will print
up to five calls to `Enum.filter`, across all processes running on the node.

```elixir
iex> require Twine
iex> Twine.print_calls(Enum.filter(list, func), 5)
1 function(s) matched, waiting for calls...
:ok
iex>
[2025-07-27 20:28:50.233475Z] #PID<0.177.0> - Enum.filter([1, 2, 3], #Function<42.39164016/1 in :erl_eval.expr/6>)
[2025-07-27 20:29:04.511325Z] #PID<0.177.0> - Enum.filter([], #Function<42.39164016/1 in :erl_eval.expr/6>)
[2025-07-27 20:29:19.975102Z] #PID<0.177.0> - Enum.filter([4, 5, 6], #Function<42.39164016/1 in :erl_eval.expr/6>)
```


You can also refine your matches by using pattern matching. For instance, this
will print up to five calls to `Enum.filter/2` with a non-empty list.
```elixir
iex> require Twine
iex> Twine.print_calls(Enum.filter([head | rest], func), 5)
1 function(s) matched, waiting for calls...
:ok
iex>
[2025-07-27 20:29:53.934746Z] #PID<0.177.0> - Enum.filter([1, 2, 3], #Function<42.39164016/1 in :erl_eval.expr/6>)
[2025-07-27 20:29:57.837534Z] #PID<0.177.0> - Enum.filter([4, 5, 6], #Function<42.39164016/1 in :erl_eval.expr/6>)
```

We can also use `show_outcome: true` to output the return value and location the code returns to.
```elixir
iex> require Twine
iex> Twine.print_calls(Enum.filter([head | rest], func), 5, show_outcome: true)
1 function(s) matched, waiting for calls...
:ok
iex>
[2025-09-29 21:11:14.297831Z] #PID<0.214.0> - Enum.filter([1, 2, 3], #Function<42.3316493/1 in :erl_eval.expr/6>)
                             ├ Returned: [2]
                             └ Returned to: MyModule.my_function/2

[2025-09-29 21:11:18.499838Z] #PID<0.216.0> - Enum.filter([4, 5, 6], #Function<42.3316493/1 in :erl_eval.expr/6>)
                              ├ Returned: [4, 6]
                              └ Returned to: MyModule.my_function/2
```

### Scoping Calls To A Process

Often, we are more interested in tracing what specific process is doing, rather
than when a function is called. Twine allows you to do this with the `pid`
option. For instance, this will print all the times a GenServer's `handle_call`
handler is called, up to a rate of 10 per second.

```elixir
iex> require Twine
iex> pid = Process.whereis(MyServer)
iex> Twine.print_calls(
  MyServer.handle_call(message, from, state), 
  {10, 1000},
  pid: pid
)

1 function(s) matched, waiting for calls...
:ok
iex>
[2025-07-27 20:43:27.683690Z] #PID<0.181.0> - Server.handle_call({:subscribe, "listener", #PID<0.189.0>}, {#PID<0.182.0>, [:alias | #Reference<0.0.23299.892277068.2243493891.5200>]}, %{subscribers: []})
[2025-07-27 20:43:29.700879Z] #PID<0.181.0> - Server.handle_call({:subscribe, "listener2", #PID<0.191.0>}, {#PID<0.182.0>, [:alias | #Reference<0.0.23299.892277068.2243493890.3014>]}, %{subscribers: [{"listener", #PID<0.189.0>}]})
[2025-07-27 20:44:17.312923Z] #PID<0.181.0> - Server.handle_call({:unsubscribe, "listener2"}, {#PID<0.182.0>, [:alias | #Reference<0.0.23299.892277068.2243493891.5293>]}, %{subscribers: [{"listener2", #PID<0.191.0>}, {"listener", #PID<0.189.0>}]})
```

Pattern matching works here as well, so we can filter calls to only ones we care
about. For instance, if our GenServer has a handler for a call of the form
`{:subscribe, name, pid}`, we can provide this pattern to our call to filter it.

```elixir
iex> require Twine
iex> pid = Process.whereis(MyServer)
iex> Twine.print_calls(
  MyServer.handle_call({:subscribe, name, pid}, from, state), 
  {10, 1000},
  pid: pid
)
1 function(s) matched, waiting for calls...
:ok
iex>

[2025-07-27 20:36:23.445375Z] #PID<0.196.0> - Server.handle_call({:subscribe, "listener", #PID<0.197.0>}, {#PID<0.197.0>, [:alias | #Reference<0.0.25219.3166356339.1974009859.127473>]}, %{subscribers: []})
[2025-07-27 20:37:05.858377Z] #PID<0.196.0> - Server.handle_call({:subscribe, "listener2", #PID<0.212.0>}, {#PID<0.197.0>, [:alias | #Reference<0.0.25219.3166356339.1974009859.127485>]}, %{subscribers: [{"listener", #PID<0.197.0>}]})
```

You can even use guards, if you need to refine your match further.

```elixir
iex> require Twine
iex> pid = Process.whereis(MyServer)
iex> Twine.print_calls(
  MyServer.handle_call({:subscribe, name, pid}, from, state)
    when length(state.subscribers) > 0,
  {10, 1000},
  pid: pid
)
1 function(s) matched, waiting for calls...
:ok
iex>

[2025-08-10 16:34:27.328975Z] #PID<0.202.0> - MyServer.handle_call({:subscribe, "listener2", #PID<0.203.0>}, {#PID<0.203.0>, [:alias | #Reference<0.0.25987.1847409877.3450142743.162317>]}, %{subscribers: [{"listener", #PID<0.203.0>}]})
```

### Removing Useless Information

Often, we don't really care about all the information passed to a function, and
printing all of it would be slow and be extremely noisy. For instance, in some 
systems, GenServers can hold a large amount of state, and we don't want to see
all (or any) of it when tracing calls. 

Twine allows you to do this with the `arg_mapper` and `return_mapper` options.
`arg_mapper` takes a function with the same arity as the captured function, and
returns a tuple or list of the updated arguments. For instance, this will print
all calls to the `{:subscribe, name, pid}` handler, but will replace the state
with the `:ignored` atom.

```elixir
iex> require Twine
iex> pid = Process.whereis(MyServer)
iex> Twine.print_calls(
  MyServer.handle_call({:subscribe, name, pid}, from, state), 
  {10, 1000},
  pid: pid,
  arg_mapper: fn msg, from, _state ->
    # :ignored is not special here, it is just a placeholder.
    {msg, from, :ignored}
  end,
  show_outcome: true
)
iex>
1 function(s) matched, waiting for calls...
:ok
[2025-09-30 02:40:26.349150Z] #PID<0.208.0> - MyServer.handle_call({:subscribe, "listener3", #PID<0.222.0>}, {#PID<0.221.0>, [:alias | #Reference<0.0.28291.1443443586.1280638978.194536>]}, :ignored)
                              ├ Returned: {:reply, :ok,
                              │            %{
                              │              subscribers: [
                              │                {"listener3", #PID<0.222.0>},
                              │                {"listener2", #PID<0.216.0>},
                              │                {"listener", #PID<0.214.0>}
                              │              ]
                              │            }}
                              └ Returned to: :gen_server.try_handle_call/4
```

`return_mapper` behaves identically to `arg_mapper`, but it is a 1-arity
function that replaces the return value. It has no effect if `show_outcome`
is set to `false`.

```elixir
iex> Twine.print_calls(
  MyServer.handle_call({:subscribe, name, pid}, from, state), 
  {10, 1000},
  pid: pid,
  # :ignored is not special here, it is just a placeholder.
  return_mapper: fn 
    {:noreply, _state} ->
      {:noreply, :ignored}
    {:reply, reply, _state} ->
      {:reply, reply, :ignored}
  end,
  show_outcome: true
)
1 function(s) matched, waiting for calls...
:ok
iex>
[2025-09-30 02:44:29.146149Z] #PID<0.208.0> - MyServer.handle_call(
                                {:subscribe, "listener4", #PID<0.229.0>},
                                {#PID<0.228.0>, [:alias | #Reference<0.0.29187.1443443586.1280638978.194570>]},
                                %{
                                  subscribers: [
                                    {"listener3", #PID<0.222.0>},
                                    {"listener2", #PID<0.216.0>},
                                    {"listener", #PID<0.214.0>}
                                  ]
                                }
                              )
                              ├ Returned: {:reply, :ok, :ignored}
                              └ Returned to: :gen_server.try_handle_call/4
```

We can also use `arg_mapper` or `return_mapper` (or both!) to only extract
parts of the state we are interested in. For instance, if the `state` has a
field `subscribers`, we can choose to only print that field by simply accessing
the field in our `arg_mapper`.

```elixir
iex> require Twine
iex> pid = Process.whereis(MyServer)
iex> Twine.print_calls(
  MyServer.handle_call({:subscribe, name, pid}, from, state), 
  {10, 1000},
  pid: pid,
  arg_mapper: fn msg, from, state ->
    {msg, from, state.subscribers}
  end,
  return_mapper: fn 
    {:noreply, state} ->
      state.subscribers
    {:reply, reply, state} ->
      state.subscribers
  end,
  show_outcome: true
)
1 function(s) matched, waiting for calls...
:ok
iex>
[2025-09-30 02:48:15.115291Z] #PID<0.243.0> - MyServer.handle_call({:subscribe, "listener1", #PID<0.253.0>}, {#PID<0.252.0>, [:alias | #Reference<0.0.32259.1443443586.1280638978.195228>]}, [])
                              ├ Returned: [{"listener1", #PID<0.253.0>}]
                              └ Returned to: :gen_server.try_handle_call/4

[2025-09-30 02:48:15.986114Z] #PID<0.243.0> - MyServer.handle_call({:subscribe, "listener2", #PID<0.255.0>}, {#PID<0.254.0>, [:alias | #Reference<0.0.32515.1443443586.1280638978.195256>]}, [{"listener1", #PID<0.253.0>}])
                              ├ Returned: [{"listener2", #PID<0.255.0>}, {"listener1", #PID<0.253.0>}]
                              └ Returned to: :gen_server.try_handle_call/4

[2025-09-30 02:48:17.323161Z] #PID<0.243.0> - MyServer.handle_call({:subscribe, "listener3", #PID<0.257.0>}, {#PID<0.256.0>, [:alias | #Reference<0.0.32771.1443443586.1280638978.195284>]}, [{"listener2", #PID<0.255.0>}, {"listener1", #PID<0.253.0>}])
                              ├ Returned: [
                              │             {"listener3", #PID<0.257.0>},
                              │             {"listener2", #PID<0.255.0>},
                              │             {"listener1", #PID<0.253.0>}
                              │           ]
                              └ Returned to: :gen_server.try_handle_call/4
```

### Function Outcomes

As mentioned, Twine can print the different outcomes of the functions it
traces. This behavior can be opted into with `show_outcome: true` to
`print_calls`/`recv_calls`, if your function is particularly long-running, or
you are just simply not interested in the extra output.

> #### Warning {: .warning}
>
> Displaying function outcomes requires commanding the VM to disable tail-call
> optimizations on the traced function. While in most cases this is not an
> issue, **using `show_outcome: true` in a hot tail-recursive path with
> large arguments can quickly cause the node to run out of memory**. This does
> not apply if `show_outcome: false` is used (the default).
>
> For more information, see [the Erlang `match_spec`
> docs](https://www.erlang.org/docs/28/apps/erts/match_spec.html) under
> "`return_trace`".

#### Returned Values

When a function returns without failure, Twine will print its return value and
the location to which it returned. Note that the "returned to" location is the
point where the code resumed execution after the function call. This **may not
be the same as the callsite**, such as if the traced function was called in the
tail position.

```text
[2025-09-30 03:24:33.814931Z] #PID<0.211.0> - Enum.reject([{"listener1", #PID<0.209.0>}], #Function<0.70727440/1 in MyServer.handle_call/3>)
                              ├ Returned: []
                              └ Returned to: MyServer.handle_call/3
```


#### Thrown Exceptions

When a function throws an exception, and that exception is caught, Twine
will print both the exception and where execution resumed (with the same caveat
as above).

```text
[2025-09-30 03:27:43.909256Z] #PID<0.197.0> - Enum.reject([{"listener1", #PID<0.206.0>}], #Function<0.13591050/1 in MyServer.handle_call/3>)
                              ├ Raised Exception: {:error, %RuntimeError{message: "blah"}}
                              └ Returned to: MyServer.handle_call/3
```

#### Process Termination

When the function that is being traced causes its calling process to terminate,
Twine will print the termination reason and the stacktrace of the termination.

```text
[2025-09-30 03:29:02.390940Z] #PID<0.210.0> - Enum.reject([{"listener1", #PID<0.219.0>}], #Function<0.5927936/1 in MyServer.handle_call/3>)
                              ├ Raised Exception: {:error, :function_clause}
                              └ Process Terminated: (server 0.1.0) lib/server.ex:39: anonymous fn({"listener1", #PID<0.219.0>}) in MyServer.handle_call/3
                                                    (elixir 1.18.4) lib/enum.ex:4521: Enum.reject_list/2
                                                    (server 0.1.0) lib/server.ex:39: MyServer.handle_call/3
                                                    (stdlib 7.1) gen_server.erl:2470: :gen_server.try_handle_call/4
                                                    (stdlib 7.1) gen_server.erl:2499: :gen_server.handle_msg/3
                                                    (stdlib 7.1) proc_lib.erl:333: :proc_lib.init_p_do_apply/3
```

### Stopping Tracing

When you are done tracing, you can simply call `Twine.clear()` to remove all
tracepoints.

## Troubleshooting

### No calls are printing, even though I know they're running!
First, make sure you're matching the correct process and/or function.

Assuming you've gotten both of these right, it is possible that `recon_trace`
did in fact match your call correctly, but it is taking time to generate the
output. Depending on the size of your call, this may take a couple of minutes.
You can use `arg_mapper`, `return_mapper`, and `show_outcome: false` to reduce
output size.

### Why can't I use the pin operator or shell variables in guards?
If you've attempted to use the pin operator when specifying a call, you've
likely gotten this error

```text
Call cannot contain a pattern that uses the pin operator (^)
```

Similarly, if you attempt to use a shell variable in a guard, you've also
likely gotten this error
```text
Identifiers in guard must exist in argument pattern. Invalid identifiers: ...
```

Unfortunately, `recon_trace` does not support checking these bound values when
it converts functions to matchspecs. This is a limitation of how Twine wraps
`recon_trace`.
