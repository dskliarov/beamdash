defmodule HelloPlugin do
  @moduledoc "The entry module of the hello test fixture plugin."
  use Beamdash.Plugin,
    name: "Hello",
    pages: [{"hello", "Hello", HelloPlugin.HelloLive}],
    mcp_tools: [
      {"greet", "Greet someone by name",
       %{type: "object", properties: %{name: %{type: "string"}}, required: ["name"]},
       {HelloPlugin.Tools, :greet}}
    ]
end
