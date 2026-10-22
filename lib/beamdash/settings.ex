defmodule Beamdash.Settings do
  @moduledoc """
  UI settings shared by every page. beamdash is a single-user local tool,
  so one global value is enough. Changes are broadcast on the
  `"settings"` PubSub topic as `{:beamdash_syntax, syntax}` or
  `{:beamdash_jev, enabled}`. Values last for this VM's lifetime.
  """

  @key {__MODULE__, :syntax}
  @jev_key {__MODULE__, :jev_enabled}
  @syntaxes [:erlang, :elixir]

  def syntaxes, do: @syntaxes

  @doc "`:erlang` (default) or `:elixir`."
  def syntax, do: :persistent_term.get(@key, :erlang)

  def put_syntax(syntax) when syntax in @syntaxes do
    :persistent_term.put(@key, syntax)
    Phoenix.PubSub.broadcast(Beamdash.PubSub, "settings", {:beamdash_syntax, syntax})
    :ok
  end

  @doc """
  Whether Jev analysis is enabled for this running instance. Until it is
  switched in Settings, it is on only when an API key is configured:
  setting `TYPESAFE_API_KEY` is the opt-in.
  """
  def jev_enabled? do
    case :persistent_term.get(@jev_key, :unset) do
      :unset -> Beamdash.Jev.available?()
      enabled -> enabled
    end
  end

  def put_jev_enabled(enabled) when is_boolean(enabled) do
    :persistent_term.put(@jev_key, enabled)
    Phoenix.PubSub.broadcast(Beamdash.PubSub, "settings", {:beamdash_jev, enabled})
    :ok
  end
end
