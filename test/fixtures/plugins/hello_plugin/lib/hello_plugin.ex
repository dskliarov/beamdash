defmodule HelloPlugin do
  @moduledoc "The entry module of the hello test fixture plugin."
  use Beamdash.Plugin,
    name: "Hello",
    pages: [{"hello", "Hello", HelloPlugin.HelloLive}]
end
