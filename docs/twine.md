# Twine

Twine allows you to safely introspect calls on a running Elixir system. Under a
hood, it wraps [`recon_trace`](https://ferd.github.io/recon/recon_trace.html),
a battle-tested library by the venerable Ferd, with some adaptations to make it
more useful for Elixir systems by providing better ergonomics and
Elixir-flavored output.

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
 messages will be of the form `{pid, {module, function, arguments}}`, This can
 be useful if you need to have programmatic access to the call data once it has
 been performed. 

The examples below focus primarily on `Twine.print_calls/2`, but the two have 
an identical set of arguments and are thus interchangeable.

When specifying a function to trace, you must provide the function to trace, and
limit on the number of calls you trace. The limit can be specified in one of two
ways

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
iex>
1 function(s) matched, waiting for calls...
:ok

[2025-07-27 20:36:23.445375Z] #PID<0.196.0> - Server.handle_call({:subscribe, "listener", #PID<0.197.0>}, {#PID<0.197.0>, [:alias | #Reference<0.0.25219.3166356339.1974009859.127473>]}, %{subscribers: []})
[2025-07-27 20:37:05.858377Z] #PID<0.196.0> - Server.handle_call({:subscribe, "listener2", #PID<0.212.0>}, {#PID<0.197.0>, [:alias | #Reference<0.0.25219.3166356339.1974009859.127485>]}, %{subscribers: [{"listener", #PID<0.197.0>}]})
```

### Removing Useless Information

Often, we don't really care about all the information passed to a function, and
printing all of it would be slow and be extremely noisy. For instance, in some 
systems, GenServers can hold a large amount of state, and we don't want to see
all (or any) of it when tracing calls. 

Twine allows you to do this with the `mapper` option. This option takes a
function with the same arity as the captured function, and returns a tuple or
list of the updated arguments. For instance, this will print all calls to the
`{:subscribe, name, pid}` handler, but will replace the state with the `:ignored`
atom.

```elixir
iex> require Twine
iex> pid = Process.whereis(MyServer)
iex> Twine.print_calls(
  MyServer.handle_call({:subscribe, name, pid}, from, state), 
  {10, 1000},
  pid: pid,
  mapper: fn msg, from, _state ->
    # :ignored is not special here, it is just a placeholder.
    {msg, from, :ignored}
  end
)
iex>
1 function(s) matched, waiting for calls...
:ok
[2025-07-27 20:37:47.920038Z] #PID<0.196.0> - Server.handle_call({:subscribe, "listener3", #PID<0.215.0>}, {#PID<0.197.0>, [:alias | #Reference<0.0.25219.3166356339.1974009867.127298>]}, :ignored)
```

Alternatively, we can also use `mapper` to only extract parts of the state we
are interested in. For instance, if the `state` has a field `subscribers`, we
can choose to only print that field by simply accessing the field in our
`mapper`.

```elixir
iex> require Twine
iex> pid = Process.whereis(MyServer)
iex> Twine.print_calls(
  MyServer.handle_call({:subscribe, name, pid}, from, state), 
  {10, 1000},
  pid: pid,
  mapper: fn msg, from, state ->
    {msg, from, state.subscribers}
  end
)
iex>
1 function(s) matched, waiting for calls...
:ok
[2025-07-27 20:39:31.986157Z] #PID<0.181.0> - Server.handle_call({:subscribe, "listener1", #PID<0.191.0>}, {#PID<0.182.0>, [:alias | #Reference<0.0.23299.904233524.900530177.57921>]}, [])
[2025-07-27 20:39:35.178405Z] #PID<0.181.0> - Server.handle_call({:subscribe, "listener2", #PID<0.193.0>}, {#PID<0.182.0>, [:alias | #Reference<0.0.23299.904233524.900530177.57986>]}, [{"listener1", #PID<0.191.0>}])
[2025-07-27 20:39:39.882631Z] #PID<0.181.0> - Server.handle_call({:subscribe, "listener3", #PID<0.195.0>}, {#PID<0.182.0>, [:alias | #Reference<0.0.23299.904233524.900530177.58022>]}, [{"listener2", #PID<0.193.0>}, {"listener1", #PID<0.191.0>}])
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

### Why can't I use the pin operator?
If you've attempted to use the pin operator when specifying a call, you've
likely gotten this error

```text
Call cannot contain a pattern that uses the pin operator (^)
```

Unfortunately, `recon_trace` does not support the pin operator when it converts
functions to matchspecs. This is a limitation of how Twine wraps
`recon_trace`.
