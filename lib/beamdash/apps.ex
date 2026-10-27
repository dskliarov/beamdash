defmodule Beamdash.Apps do
  @moduledoc """
  Observer's Applications tab: the running applications and, for one, its
  process tree from the application master, found by following links as
  Observer's appmon_info does (`beamdash_agent:app_tree/1`).
  """

  alias Beamdash.Target

  @doc "`[%{name, description, vsn, master}]` in `application:which_applications/0` order."
  def list(node), do: Target.rpc(node, :beamdash_agent, :applications, [])

  @doc """
  `{:ok, [{name, vsn}]}`: every running application on `node`, from
  `application:which_applications/0`, with its version as a string. Unlike
  `list/1` it includes library applications (those without an application
  master) and needs no agent. The plugins registry and
  `Beamdash.Plugin.app_version/2` both use it, so they agree.
  """
  @spec running(node()) :: {:ok, [{atom(), String.t()}]} | {:error, term()}
  def running(node) do
    case Target.rpc(node, :application, :which_applications, []) do
      {:ok, apps} when is_list(apps) ->
        {:ok, for({name, _desc, vsn} <- apps, do: {name, vsn_string(vsn)})}

      {:ok, other} ->
        {:error, {:unexpected, other}}

      error ->
        error
    end
  end

  defp vsn_string(vsn) do
    case :unicode.characters_to_binary(vsn) do
      bin when is_binary(bin) -> bin
      _ -> ""
    end
  rescue
    _ -> ""
  end

  @doc """
  The process tree of `app`: `%{pid, name, label, children: [node], also:
  [pid]}`, where `also` are its secondary links (shown dashed in Observer),
  plus the number of processes. `{:ok, nil}` when the application is gone.
  """
  def tree(node, app) do
    case Target.rpc(node, :beamdash_agent, :app_tree, [app]) do
      {:ok, :undefined} -> {:ok, nil}
      {:ok, raw} -> {:ok, build(raw)}
      error -> error
    end
  end

  @doc false
  def build(%{root: root, procs: procs, links: links, extra: extra}) do
    info = Map.new(procs, &{&1.pid, &1})

    kids =
      links
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    also =
      Enum.reduce(extra, %{}, fn {a, b}, acc ->
        acc |> Map.update(a, [b], &[b | &1]) |> Map.update(b, [a], &[a | &1])
      end)

    {tree, seen} = walk(root, kids, info, also, MapSet.new([root]))
    %{root: tree, count: MapSet.size(seen)}
  end

  # A child linked from two parents is drawn under the first one reached.
  defp walk(pid, kids, info, also, seen) do
    {children, seen} =
      kids
      |> Map.get(pid, [])
      |> Enum.uniq()
      |> Enum.reduce({[], seen}, fn child, {acc, seen} ->
        if MapSet.member?(seen, child) or not Map.has_key?(info, child) do
          {acc, seen}
        else
          {node, seen} = walk(child, kids, info, also, MapSet.put(seen, child))
          {[node | acc], seen}
        end
      end)

    p = Map.get(info, pid, %{name: :undefined, label: :undefined})

    {%{
       pid: pid,
       name: present(p.name),
       label: present(p.label),
       children: Enum.reverse(children),
       also: also |> Map.get(pid, []) |> Enum.uniq()
     }, seen}
  end

  defp present(:undefined), do: nil
  defp present(v), do: v
end
