defmodule Beamdash.Mcp do
  @moduledoc """
  The read-only tools the MCP endpoint (`BeamdashWeb.McpPlug`) offers to a
  coding agent. Each one reads the node beamdash is attached to through the
  same calls the web pages use, and returns plain data. Crashes and logs are
  what beamdash has already collected from the node. Active plugins add
  their own tools, named `<app>.<tool>`.
  """

  alias Beamdash.{
    Apps,
    Crashes,
    Format,
    Logs,
    Memory,
    Plugins,
    Settings,
    SourceCheck,
    Store,
    Target
  }

  @default_limit 100
  @max_limit 1000
  @default_window 60
  @max_window 10_080
  @plugin_tool_timeout 5_000

  @tools [
    %{
      name: "node_info",
      description:
        "The attached node: name, OTP release, ERTS version, process count, total memory, schedulers and uptime.",
      inputSchema: %{type: "object", properties: %{}}
    },
    %{
      name: "list_processes",
      description:
        "The processes of the attached node, largest memory first. Each has a pid to pass to process_details.",
      inputSchema: %{
        type: "object",
        properties: %{
          limit: %{
            type: "integer",
            description: "How many to return (default #{@default_limit}, at most #{@max_limit})."
          }
        }
      }
    },
    %{
      name: "process_details",
      description: "Memory, garbage collection, reductions and mailbox of one process.",
      inputSchema: %{
        type: "object",
        properties: %{
          pid: %{
            type: "string",
            description: "The pid as list_processes shows it, e.g. <0.123.0>."
          }
        },
        required: ["pid"]
      }
    },
    %{
      name: "ets_tables",
      description:
        "The ETS tables of the attached node, largest memory first: name, type, size, memory and owner.",
      inputSchema: %{type: "object", properties: %{}}
    },
    %{
      name: "app_list",
      description:
        "The applications running on the attached node, as the Applications tab lists them: name, description, version and master.",
      inputSchema: %{type: "object", properties: %{}}
    },
    %{
      name: "app_info",
      description:
        "One application: description, version, start type, folder, environment, the applications that need it and its module count.",
      inputSchema: %{
        type: "object",
        properties: %{
          app: %{type: "string", description: "The application name, as app_list shows it."}
        },
        required: ["app"]
      }
    },
    %{
      name: "app_tree",
      description:
        "The process tree of one application, from its application master: each process's name, label and children, and its secondary links (`also`).",
      inputSchema: %{
        type: "object",
        properties: %{
          app: %{type: "string", description: "The application name, as app_list shows it."}
        },
        required: ["app"]
      }
    },
    %{
      name: "module_summary",
      description:
        "A loaded module: its file, version, behaviours, exports, owning application and whether its source is available. `source` is the source path it was compiled from, on the node; `local_file` is the source file on this computer, when a source folder in beamdash's settings has it.",
      inputSchema: %{
        type: "object",
        properties: %{
          module: %{type: "string", description: "The module name, e.g. lists."}
        },
        required: ["module"]
      }
    },
    %{
      name: "crashes",
      description:
        "Recent crash reports from the node, newest first: the process, its initial call, the class and reason of the crash, and the stack.",
      inputSchema: %{
        type: "object",
        properties: %{
          limit: %{
            type: "integer",
            description: "How many to return (default #{@default_limit}, at most #{@max_limit})."
          }
        }
      }
    },
    %{
      name: "logs",
      description:
        "Recent log lines from the node, newest first: time, level, process, location and message.",
      inputSchema: %{
        type: "object",
        properties: %{
          limit: %{
            type: "integer",
            description: "How many to return (default #{@default_limit}, at most #{@max_limit})."
          },
          level: %{type: "string", description: "Only lines at this level, e.g. error."}
        }
      }
    },
    %{
      name: "snapshots",
      description:
        "Process snapshots stored from the attached node, newest first: when each was taken, the process pid, the reason (load, memory or heap_rising), and the process data. Needs snapshot collection on in beamdash's settings.",
      inputSchema: %{
        type: "object",
        properties: %{
          window: %{
            type: "integer",
            description:
              "Minutes to look back (default #{@default_window}, at most #{@max_window})."
          },
          reason: %{type: "string", description: "Only snapshots taken for this reason."},
          pid: %{type: "string", description: "Only this process, e.g. <0.123.0>."},
          limit: %{
            type: "integer",
            description: "How many to return (default #{@default_limit}, at most #{@max_limit})."
          }
        }
      }
    },
    %{
      name: "anomaly_history",
      description:
        "Anomaly episodes stored from the attached node, newest first: when each started, the process pid, the measure, how long it lasted and what beamdash said about it. Needs snapshot collection on in beamdash's settings.",
      inputSchema: %{
        type: "object",
        properties: %{
          window: %{
            type: "integer",
            description:
              "Minutes to look back (default #{@default_window}, at most #{@max_window})."
          },
          measure: %{type: "string", description: "Only episodes of this measure."},
          pid: %{type: "string", description: "Only this process, e.g. <0.123.0>."},
          limit: %{
            type: "integer",
            description: "How many to return (default #{@default_limit}, at most #{@max_limit})."
          }
        }
      }
    },
    %{
      name: "memory_history",
      description:
        "Memory samples stored from the attached node, newest first: when each was taken, total memory, atom count and ETS table count. With `table`, that ETS table's type, size, memory and owner at each sample; `table` is null when it was not among the largest tables then. Needs snapshot collection on in beamdash's settings.",
      inputSchema: %{
        type: "object",
        properties: %{
          window: %{
            type: "integer",
            description: "Minutes to look back (default 1440, at most #{@max_window})."
          },
          table: %{type: "string", description: "Only this ETS table, e.g. rig_locks."},
          limit: %{
            type: "integer",
            description: "How many samples to return (default 500, at most #{@max_limit})."
          }
        }
      }
    },
    %{
      name: "ets_rows",
      description:
        "Up to 20 rows of one ETS table of the attached node, read within one second. Each row is a term shown as text. `keypos` is the position of the key in a row. `stop` says why the read ended: complete, rows (the limit was reached) or time.",
      inputSchema: %{
        type: "object",
        properties: %{
          table: %{type: "string", description: "The table name, as ets_tables shows it."},
          limit: %{type: "integer", description: "How many rows (default 10, at most 20)."}
        },
        required: ["table"]
      }
    },
    %{
      name: "source_check",
      description:
        "Whether the source folder beamdash has for an application is the code the node runs: the commit in its version against the folder's git HEAD, and any uncommitted changes. `status` is match, mismatch, dirty, no_ref, no_git or no_folder. The folder comes from beamdash's settings (source folders).",
      inputSchema: %{
        type: "object",
        properties: %{
          app: %{type: "string", description: "The application name, as app_list shows it."}
        },
        required: ["app"]
      }
    }
  ]

  @names Enum.map(@tools, & &1.name)

  def tools(plugins \\ Plugins) do
    @tools ++ for {app, tool} <- plugin_tools(plugins), do: public_tool(app, tool)
  end

  def call(name, args, server \\ Target, plugins \\ Plugins)

  def call(name, args, server, _plugins) when name in @names do
    case Target.status(server) do
      %{status: :connected, node: node} -> run(name, args, node, server)
      _ -> {:error, "beamdash is not connected to a node"}
    end
  end

  def call(name, args, _server, plugins) do
    case Enum.find(plugin_tools(plugins), fn {app, tool} -> tool_name(app, tool) == name end) do
      {_app, tool} -> run_plugin_tool(tool, name, args)
      nil -> :unknown_tool
    end
  end

  defp run("node_info", _args, _node, server), do: answer(Target.node_info(server))

  defp run("list_processes", args, _node, server) do
    case Target.process_list(server) do
      {:ok, {procs, _info}} ->
        {:ok, procs |> sort_by_memory() |> Enum.take(limit(args)) |> json()}

      other ->
        answer(other)
    end
  end

  defp run("process_details", args, node, server) do
    case Target.parse_pid(args["pid"], node) do
      pid when is_pid(pid) ->
        case Target.process_details(pid, 0, server) do
          {:ok, :undefined} -> {:error, "that process has exited"}
          other -> answer(other)
        end

      _ ->
        {:error, "pid must look like <0.123.0>, as list_processes shows it"}
    end
  end

  defp run("ets_tables", _args, node, _server) do
    case Memory.ets_tables(node) do
      {:ok, tables} -> {:ok, tables |> sort_by_memory() |> json()}
      other -> answer(other)
    end
  end

  defp run("app_list", _args, node, _server), do: answer(Apps.list(node))

  defp run("app_info", args, node, _server) do
    with {:ok, app} <- app_name(args), do: found(Apps.info(node, app), app)
  end

  defp run("app_tree", args, node, _server) do
    with {:ok, app} <- app_name(args), do: found(Apps.tree(node, app), app)
  end

  defp run("module_summary", args, node, _server) do
    with {:ok, mod} <- module_name(args) do
      case Apps.module_summary(node, mod) do
        nil -> {:error, "#{mod} is not loaded on the node, or the node did not say"}
        summary -> {:ok, json(summary)}
      end
    end
  end

  defp run("crashes", args, _node, _server) do
    reports = Crashes.reports() |> Enum.take(limit(args))
    {:ok, json(Enum.map(reports, &%{&1 | at: iso(&1.at)}))}
  end

  defp run("logs", args, _node, _server) do
    entries =
      Logs.entries()
      |> filter_level(args)
      |> Enum.take(limit(args))
      |> Enum.map(
        &%{at: iso(&1.at), level: &1.level, pid: &1.pid, where: &1.where, message: &1.message}
      )

    {:ok, json(entries)}
  end

  defp run("snapshots", args, node, _server), do: stored(:snapshots, args, node, [:reason])

  defp run("anomaly_history", args, node, _server),
    do: stored(:anomalies, args, node, [:measure])

  defp run("memory_history", args, node, _server) do
    with :ok <- collecting() do
      max = limit(args, 500)
      from = System.system_time(:millisecond) - window(args, 1_440) * 60_000
      table = arg(args, "table")
      rows = Store.query(:memory, node: node, from: from, limit: max + 1)

      {:ok,
       json(%{
         rows: rows |> Enum.take(max) |> Enum.map(&memory_point(&1, table)),
         truncated: length(rows) > max
       })}
    end
  end

  defp run("ets_rows", args, node, _server) do
    with {:ok, table} <- table_name(args) do
      case Memory.ets_browse(node, table, [{:_, [], [:"$_"]}], limit(args, 10, 20), 1_000) do
        {:ok, {:error, reason}} ->
          {:error, ets_error(table, reason)}

        {:ok, found} when is_map(found) ->
          {:ok, json(Map.put(Map.take(found, [:rows, :keypos, :stop]), :table, table))}

        other ->
          answer(other)
      end
    end
  end

  defp run("source_check", args, node, _server) do
    with {:ok, app} <- app_name(args), do: source_check(node, app)
  end

  defp stored(kind, args, node, keys) do
    with :ok <- collecting(),
         {:ok, opts} <- query_opts(args, node, keys) do
      rows = Store.query(kind, [limit: limit(args)] ++ opts)
      {:ok, json(Enum.map(rows, &stored_row/1))}
    end
  end

  defp collecting do
    cond do
      not Settings.snapshots_enabled?() ->
        {:error, "snapshot collection is off; turn it on in beamdash's settings"}

      Process.whereis(Store) == nil ->
        {:error, "the event store is not running"}

      true ->
        :ok
    end
  end

  defp query_opts(args, node, keys) do
    with {:ok, pid} <- pid_arg(args) do
      filters =
        for key <- keys,
            value <- [arg(args, Atom.to_string(key))],
            is_binary(value),
            do: {key, value}

      from = System.system_time(:millisecond) - window(args) * 60_000
      opts = [node: node, from: from] ++ filters
      {:ok, if(pid, do: [{:pid, pid} | opts], else: opts)}
    end
  end

  defp pid_arg(args) do
    case arg(args, "pid") do
      nil -> {:ok, nil}
      "<" <> _ = pid -> {:ok, "#PID" <> pid}
      "#PID<" <> _ = pid -> {:ok, pid}
      _ -> {:error, "pid must look like <0.123.0>, as list_processes shows it"}
    end
  end

  defp stored_row(row) do
    row
    |> Map.drop([:id, :node])
    |> Map.update!(:at, &iso(DateTime.from_unix!(&1, :millisecond)))
    |> Map.update!(:pid, &String.replace_prefix(&1, "#PID", ""))
    |> json()
  end

  defp memory_point(row, table) do
    point = %{
      at: iso(DateTime.from_unix!(row.at, :millisecond)),
      memory: get_in(row.data, ["memory", "total"]),
      atom_count: row.data["atom_count"],
      ets_count: row.data["ets_count"]
    }

    if table, do: Map.put(point, :table, table_entry(row.data, table)), else: point
  end

  defp table_entry(data, table) do
    case Enum.find(data["tables"] || [], &(&1["name"] == table)) do
      nil ->
        nil

      entry ->
        %{
          name: entry["name"],
          type: entry["type"],
          size: entry["size"],
          memory: entry["memory"],
          owner: entry["owner"]
        }
    end
  end

  defp table_name(%{"table" => name}) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, "no table named #{name} is known; take the name from ets_tables"}
  end

  defp table_name(_args), do: {:error, "table must be the ETS table name, as ets_tables shows it"}

  defp ets_error(table, :no_table), do: "no ETS table named #{table} on the node"
  defp ets_error(table, :private), do: "#{table} is private: only its owner can read it"
  defp ets_error(table, reason), do: "#{table} cannot be read: #{inspect(reason)}"

  defp source_check(node, app) do
    case Apps.info(node, app) do
      {:ok, nil} ->
        {:error, "#{app} is not on the node"}

      {:ok, %{vsn: vsn}} ->
        folder = Settings.source_dirs()[Atom.to_string(app)]

        {:ok,
         json(Map.merge(%{app: app, vsn: vsn, folder: folder}, SourceCheck.check(vsn, folder)))}

      other ->
        answer(other)
    end
  end

  defp plugin_tools(plugins) do
    for %{app: app, mcp_tools: tools} <- Plugins.active(plugins), tool <- tools, do: {app, tool}
  end

  defp tool_name(app, tool), do: "#{app}.#{tool.name}"

  defp public_tool(app, tool),
    do: %{
      name: tool_name(app, tool),
      description: tool.description,
      inputSchema: tool.input_schema
    }

  defp run_plugin_tool(tool, name, args) do
    case missing_args(tool.input_schema, args) do
      [] -> call_plugin_tool(tool, name, args)
      missing -> {:error, "#{name} needs #{Enum.join(missing, ", ")}"}
    end
  end

  defp missing_args(schema, args) do
    required = Map.get(schema, :required, [])
    if is_map(args), do: Enum.reject(required, &Map.has_key?(args, &1)), else: required
  end

  defp call_plugin_tool(%{call: {mod, fun}}, name, args) do
    task =
      Task.async(fn ->
        try do
          case apply(mod, fun, [args]) do
            {:ok, data} -> {:ok, json(data)}
            {:error, message} when is_binary(message) -> {:error, message}
            other -> {:error, "#{name} returned #{inspect(other)}"}
          end
        rescue
          e -> {:error, "#{name} raised #{Exception.message(e)}"}
        catch
          kind, reason -> {:error, "#{name} failed: #{inspect({kind, reason})}"}
        end
      end)

    case Task.yield(task, @plugin_tool_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, reply} -> reply
      nil -> {:error, "#{name} did not answer in #{div(@plugin_tool_timeout, 1000)} seconds"}
    end
  end

  defp answer({:ok, data}), do: {:ok, json(data)}
  defp answer({:error, reason}), do: {:error, "the node did not answer: #{inspect(reason)}"}

  defp found({:ok, nil}, name), do: {:error, "#{name} is not on the node"}
  defp found(other, _name), do: answer(other)

  defp app_name(%{"app" => name}) when is_binary(name), do: known_atom(name, "application")
  defp app_name(_args), do: {:error, "app must be the application name, as app_list shows it"}

  defp module_name(%{"module" => name}) when is_binary(name) do
    case known_atom("Elixir." <> name, "module") do
      {:ok, _} = found -> found
      _ -> known_atom(name, "module")
    end
  end

  defp module_name(_args), do: {:error, "module must be the module name, e.g. lists"}

  defp known_atom(name, kind) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError ->
      {:error,
       "no #{kind} named #{name} is known; take the name from app_list, a process or a log line"}
  end

  defp filter_level(entries, %{"level" => level}) when is_binary(level),
    do: Enum.filter(entries, &(to_string(&1.level) == level))

  defp filter_level(entries, _args), do: entries

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(other), do: other

  defp sort_by_memory(list), do: Enum.sort_by(list, & &1.memory, :desc)

  defp limit(args, default \\ @default_limit, max \\ @max_limit)

  defp limit(%{"limit" => n}, _default, max) when is_integer(n) and n > 0, do: min(n, max)
  defp limit(_args, default, _max), do: default

  defp window(args, default \\ @default_window) do
    case arg(args, "window") do
      n when is_integer(n) and n > 0 -> min(n, @max_window)
      _ -> default
    end
  end

  defp arg(args, key) when is_map(args), do: Map.get(args, key)
  defp arg(_args, _key), do: nil

  defp json(pid) when is_pid(pid), do: Format.pid(pid)
  defp json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {json(k), json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)

  defp json(text) when is_binary(text) do
    if String.valid?(text), do: text, else: inspect(text)
  end

  defp json(term) when is_atom(term) or is_number(term), do: term
  defp json(term), do: inspect(term)
end
