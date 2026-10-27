defmodule Beamdash.Plugins.Compat do
  @moduledoc """
  Whether a plugin fits the attached node: compares the applications it
  supports (from its `mix.exs`) with the node's running applications.
  """

  @type supports :: [{atom(), String.t() | nil}]
  @type running :: [{atom(), String.t()}]
  @type status :: :active | :waiting | {:incompatible, atom(), String.t(), String.t()}

  @doc """
  `:active` when a supported application runs at a matching version,
  `{:incompatible, app, running_vsn, requirement}` (the first supported one
  that runs) when some run but none matches, `:waiting` when none runs.

  A `nil` requirement matches any version. A leading `v` of a running
  version is dropped (`"v0.11.0"` is `"0.11.0"`), and one that isn't SemVer
  is padded (`"2.1"` is `"2.1.0"`); one that still doesn't parse matches no
  requirement.
  """
  @spec status(supports(), running()) :: status()
  def status(supports, running) do
    vsns = Map.new(running)
    present = for {app, req} <- supports, Map.has_key?(vsns, app), do: {app, req, vsns[app]}

    cond do
      present == [] ->
        :waiting

      Enum.any?(present, fn {_app, req, vsn} -> matches?(vsn, req) end) ->
        :active

      true ->
        {app, req, vsn} = hd(present)
        {:incompatible, app, vsn, req}
    end
  end

  @doc "Why an `{:incompatible, ...}` plugin isn't shown, for the page."
  @spec reason(status()) :: String.t()
  def reason({:incompatible, app, vsn, req}) do
    if parse(vsn) == :error,
      do: "#{app} #{vsn} is running, which isn't a valid version; this plugin supports #{req}",
      else: "#{app} #{vsn} is running; this plugin supports #{req}"
  end

  defp matches?(_vsn, nil), do: true

  defp matches?(vsn, req) do
    with {:ok, version} <- parse(vsn),
         {:ok, requirement} <- Version.parse_requirement(req) do
      Version.match?(version, requirement, allow_pre: true)
    else
      _ -> false
    end
  end

  defp parse("v" <> vsn), do: parse(vsn)

  defp parse(vsn) do
    case Version.parse(vsn) do
      {:ok, _} = ok -> ok
      :error -> vsn |> pad() |> Version.parse()
    end
  end

  defp pad(vsn) do
    case String.split(vsn, ".") do
      [major] -> "#{major}.0.0"
      [major, minor] -> "#{major}.#{minor}.0"
      _ -> vsn
    end
  end
end
