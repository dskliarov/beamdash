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
  What `app` is: `%{description, vsn, id, mod, applications,
  included_applications, optional_applications, registered, modules,
  start_phases, start_type, path, env, needed_by}`, from
  `application:get_all_key/1` (`modules` is their number), `get_all_env/1`
  (`env`, sorted), its start type (`:permanent`, `:transient`,
  `:temporary`; `nil` if not started), its folder (`code:lib_dir/1`; `nil`
  if there is none) and the running applications that need it
  (`needed_by`). `{:ok, nil}` when it isn't loaded.
  """
  def info(node, app) do
    case Target.rpc(node, :beamdash_agent, :app_info, [app]) do
      {:ok, :undefined} ->
        {:ok, nil}

      {:ok, info} ->
        {:ok, Map.new(info, fn {k, v} -> {k, if(v == :undefined, do: nil, else: v)} end)}

      error ->
        error
    end
  end

  @doc """
  A process of an application's tree, for the Apps tab: `%{process,
  module}`. `process` is `beamdash_agent:process_details/2` without its
  queued messages; `module` is `beamdash_agent:module_summary/1` of the
  module that implements it (see `process_module/1`), or `nil`.
  `{:ok, nil}` when the process has exited.
  """
  def process(node, pid) when is_pid(pid) do
    case Target.rpc(node, :beamdash_agent, :process_details, [pid, -1]) do
      {:ok, :undefined} ->
        {:ok, nil}

      {:ok, details} ->
        {:ok, %{process: details, module: module_summary(node, process_module(details))}}

      error ->
        error
    end
  end

  @doc """
  `beamdash_agent:module_summary/1` of `mod` on `node`: `%{module, file,
  source, vsn, behaviours, exports, application}` (`source` and
  `application` are `nil` when unknown) and `has_source` (on the node, or
  in a local source folder, see `Beamdash.LocalSource`), or `nil` when it
  isn't loaded or can't be asked.
  """
  def module_summary(node, mod, find_local \\ &Beamdash.LocalSource.find/2)

  def module_summary(_node, nil, _find_local), do: nil

  def module_summary(node, mod, find_local) when is_atom(mod) do
    case Target.rpc(node, :beamdash_agent, :module_summary, [mod]) do
      {:ok, summary} when is_map(summary) ->
        summary
        |> Map.new(fn {k, v} -> {k, if(v == :undefined, do: nil, else: v)} end)
        |> local_source(node, mod, find_local)

      _ ->
        nil
    end
  end

  # no source on the node: a local source folder may have it
  defp local_source(%{has_source: false} = summary, node, mod, find_local),
    do: %{summary | has_source: match?({:ok, _}, find_local.(node, mod))}

  defp local_source(summary, _node, _mod, _find_local), do: summary

  @doc """
  The module that implements a process (`details` from
  `beamdash_agent:process_details/2`): its initial call's module, which for
  a gen_server and the like is the callback module, else (a spawned fun,
  started with `erlang:apply/2`) the module of the function it runs now.
  A supervisor's initial call is `{supervisor, callback_module, 1}`.
  """
  def process_module(%{initial_call: {:supervisor, mod, 1}}) when is_atom(mod), do: mod

  def process_module(%{initial_call: {mod, _, _}}) when mod not in [:erlang, :proc_lib],
    do: mod

  def process_module(%{current_function: {mod, _, _}}), do: mod
  def process_module(_details), do: nil

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
