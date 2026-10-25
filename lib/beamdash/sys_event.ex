defmodule Beamdash.SysEvent do
  @moduledoc """
  Describes sys debug events in the words `sys:trace/2` prints them with on
  the target ("got call ... from ...", "receive cast ... in state ..."),
  but with terms in the chosen syntax.

  Returns `{tag, text}`: a short tag (call, cast, info, reply, state, …)
  and the rest of the line.
  """

  alias Beamdash.Format

  @max 200

  def describe(event, syntax \\ :erlang)

  # beamdash's own marker: the traced process exited
  def describe({:beamdash_exited, reason}, s), do: {"exit", "process exited: #{t(reason, s)}"}

  ## gen_server

  def describe({:in, {:"$gen_call", {from, _tag}, call}}, s),
    do: {"call", "got call #{t(call, s)} from #{who(from, s)}"}

  def describe({:in, {:"$gen_cast", cast}}, s), do: {"cast", "got cast #{t(cast, s)}"}

  def describe({:out, reply, {to, _tag}, state}, s),
    do: {"reply", "sent #{t(reply, s)} to #{who(to, s)}, new state #{t(state, s)}"}

  def describe({:out, msg, to, state}, s),
    do: {"sent", "sent #{t(msg, s)} to #{who(to, s)}, new state #{t(state, s)}"}

  def describe({:noreply, state}, s), do: {"state", "new state #{t(state, s)}"}

  ## gen_statem (events carry the state machine's state)

  def describe({:in, {{:call, {from, _tag}}, req}, state}, s),
    do: {"call", "receive call #{t(req, s)} from #{who(from, s)} in state #{t(state, s)}"}

  def describe({:in, {type, content}, state}, s) when is_atom(type),
    do: {to_string(type), "receive #{type} #{t(content, s)} in state #{t(state, s)}"}

  def describe({:out, reply, {to, _tag}}, s),
    do: {"reply", "send #{t(reply, s)} to #{who(to, s)}"}

  def describe({:consume, {{:call, {from, _tag}}, req}, state, next}, s),
    do: {"consume", "consume call #{t(req, s)} from #{who(from, s)}#{states(state, next, s)}"}

  def describe({:consume, {type, content}, state, next}, s) when is_atom(type),
    do: {"consume", "consume #{type} #{t(content, s)}#{states(state, next, s)}"}

  def describe({:start_timer, action, state}, s),
    do: {"timer", "start_timer #{t(action, s)} in state #{t(state, s)}"}

  def describe({:enter, module, state}, s) when is_atom(module),
    do: {"enter", "enter #{t(state, s)}"}

  def describe({:terminate, reason, state}, s),
    do: {"terminate", "terminate #{t(reason, s)} in state #{t(state, s)}"}

  ## gen_server info messages (after the gen_statem clauses: {in, Msg} has
  ## two elements, theirs three)

  def describe({:in, msg}, s), do: {"info", "got #{t(msg, s)}"}
  def describe({:in, msg, from}, s), do: {"in", "got #{t(msg, s)} from #{who(from, s)}"}

  ## anything else (gen_event, supervisor, newer OTP releases)

  def describe(event, s)
      when is_tuple(event) and tuple_size(event) > 0 and is_atom(elem(event, 0)) do
    [tag | rest] = Tuple.to_list(event)
    {to_string(tag), Enum.map_join(rest, " ", &t(&1, s))}
  end

  def describe(event, s), do: {"event", t(event, s)}

  defp states(state, state, s), do: " in state #{t(state, s)}"
  defp states(state, next, s), do: " in state #{t(state, s)} → #{t(next, s)}"

  defp who(pid, s) when is_pid(pid), do: Format.pid(pid, s)
  defp who(other, s), do: t(other, s)

  defp t(term, s), do: Format.term(term, s, @max)
end
