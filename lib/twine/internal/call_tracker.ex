defmodule Twine.Internal.CallTracker do
  @moduledoc false
  # This module tracks calls for the Internal module. There is absolutely no
  # guarantee around its stability

  use Agent

  def start_link() do
    Agent.start_link(fn -> %{} end)
  end

  def log_call(tracker, pid, mfa) do
    Agent.update(tracker, fn %{} = state ->
      Map.put(state, {pid, normalize_mfa(mfa)}, mfa)
    end)
  end

  def pop_call(tracker, pid, mfa) do
    Agent.get_and_update(tracker, fn %{} = state ->
      Map.pop(state, {pid, normalize_mfa(mfa)})
    end)
  end

  defp normalize_mfa({mod, function, args}) when is_integer(args) do
    {mod, function, args}
  end

  defp normalize_mfa({mod, function, args}) when is_list(args) do
    {mod, function, Enum.count(args)}
  end
end
