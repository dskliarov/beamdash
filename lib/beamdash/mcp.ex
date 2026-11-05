defmodule Beamdash.Mcp do
  @moduledoc """
  The read-only tools the MCP endpoint (`BeamdashWeb.McpPlug`) offers to a
  coding agent. Each one reads the node beamdash is attached to through the
  same calls the web pages use, and returns plain data.
  """

  alias Beamdash.{Format, Memory, Target}

  @default_limit 100
  @max_limit 1000

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
    }
  ]

  @names Enum.map(@tools, & &1.name)

  def tools, do: @tools

  def call(name, args, server \\ Target)

  def call(name, args, server) when name in @names do
    case Target.status(server) do
      %{status: :connected, node: node} -> run(name, args, node, server)
      _ -> {:error, "beamdash is not connected to a node"}
    end
  end

  def call(_name, _args, _server), do: :unknown_tool

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
        case Target.process_details(pid, 100, server) do
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

  defp answer({:ok, data}), do: {:ok, json(data)}
  defp answer({:error, reason}), do: {:error, "the node did not answer: #{inspect(reason)}"}

  defp sort_by_memory(list), do: Enum.sort_by(list, & &1.memory, :desc)

  defp limit(%{"limit" => n}) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp limit(_args), do: @default_limit

  defp json(pid) when is_pid(pid), do: Format.pid(pid)
  defp json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {json(k), json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)

  defp json(text) when is_binary(text) do
    if String.valid?(text), do: text, else: inspect(text)
  end

  defp json(term) when is_atom(term) or is_number(term), do: term
  defp json(term), do: inspect(term)
end
