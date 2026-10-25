defmodule Beamdash.Plugin.Format do
  @moduledoc """
  Formatting helpers for plugin pages, the same ones beamdash's own pages
  use. `syntax` is `:erlang` or `:elixir`; pages get it as `@syntax`.
  """

  @doc "A term, as text in `syntax`, cut to about `max` characters."
  defdelegate term(term, syntax \\ :erlang, max \\ 160), to: Beamdash.Format

  @doc "A pid as text: `<0.1.0>` in Erlang syntax, `#PID<0.1.0>` in Elixir."
  defdelegate pid(pid, syntax \\ :erlang), to: Beamdash.Format

  @doc "`{m, f, arity}` (or `{m, f, args}`) as text: `lists:map/2` or `:lists.map/2`."
  defdelegate mfa(mfa, syntax \\ :erlang), to: Beamdash.Format

  @doc "A byte count as text: `512 B`, `2.0 KB`, `1.5 MB` or `3.2 GB`."
  defdelegate bytes(n), to: Beamdash.Format
end
