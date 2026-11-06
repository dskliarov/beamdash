defmodule HelloPlugin.Tools do
  @moduledoc "The MCP tools of the hello test fixture plugin."

  def greet(%{"name" => name}), do: {:ok, %{greeting: "Hello, #{name}!"}}
end
