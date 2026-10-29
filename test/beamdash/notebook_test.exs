defmodule Beamdash.NotebookTest do
  use ExUnit.Case, async: true
  alias Beamdash.Notebook

  @source """
  <!-- livebook:{"persist_outputs":true} -->

  # Node inspection

  ```elixir
  x = 21
  ```

  ## Inspect

  Notes with **Markdown**.

  ```elixir
  x * 2
  ```

  <!-- livebook:{"output":true} -->

  ```
  42
  ```
  """

  test "imports LiveMarkdown setup, sections, cells and persisted outputs without changing bytes" do
    assert {:ok, notebook} = Notebook.from_livemd(@source)
    assert Notebook.to_livemd(notebook) == @source
    assert notebook.title == "Node inspection"
    assert Enum.count(notebook.blocks, & &1.executable) == 2
    assert Enum.any?(notebook.blocks, &(&1.kind == :output and &1.source == "42"))
  end

  test "preserves opaque metadata and prevents execution of smart and forced Markdown cells" do
    source =
      "# Test\n\n<!-- livebook:{\"force_markdown\":true} -->\n```elixir\nnot_a_cell()\n```\n\n<!-- livebook:{\"livebook_object\":\"smart_cell\",\"kind\":\"db\",\"attrs\":\"abc\"} -->\n```elixir\nquery()\n```\n\n```python\nx = 1\n```\n"

    {:ok, notebook} = Notebook.from_livemd(source)
    assert Notebook.to_livemd(notebook) == source
    refute Enum.any?(notebook.blocks, & &1.executable)
    assert notebook.warnings != []
  end

  test "editing code uses safe fences, drops stale outputs and preserves metadata" do
    {:ok, notebook} = Notebook.from_livemd(@source)
    cell = Enum.filter(notebook.blocks, & &1.executable) |> List.last()
    notebook = Notebook.update(notebook, cell.id, "\"```\"", nil)
    source = Notebook.to_livemd(notebook)
    assert source =~ "````elixir"
    assert source =~ "persist_outputs"
    refute source =~ ~s("output":true)
    assert {:ok, reimported} = Notebook.from_livemd(source)
    assert Enum.any?(reimported.blocks, &(&1.source == "\"```\"" and &1.executable))
  end

  test "new and appended cells are LiveMarkdown and can be reopened" do
    notebook = Notebook.new() |> Notebook.append(:markdown) |> Notebook.append(:erlang)
    assert {:ok, reopened} = Notebook.from_livemd(Notebook.to_livemd(notebook))
    assert Enum.any?(reopened.blocks, &(&1.language == :erlang and &1.executable))
  end

  test "renders Markdown without allowing HTML or javascript links" do
    html =
      Notebook.markdown_html(
        "# Heading\n\n**Bold** [bad](javascript:alert)\n\n<script>alert(1)</script>"
      )

    assert html =~ "<h1>"
    assert html =~ "<strong>Bold</strong>"
    refute html =~ "href=\"javascript:"
    refute html =~ "<script>"
  end

  test "supports tilde fences, CRLF and code-looking persisted output" do
    source =
      "# Test\r\n\r\n~~~~erlang\r\nnode().\r\n~~~~\r\n\r\n<!-- livebook:{\"output\":true} -->\r\n```elixir\r\nnever_run()\r\n```\r\n"

    {:ok, notebook} = Notebook.from_livemd(source)
    assert Notebook.to_livemd(notebook) == source
    assert Enum.count(notebook.blocks, & &1.executable) == 1
  end

  test "exports textual results in Livebook output blocks and removes an edited signature" do
    source =
      "# Test\n\n```elixir\n1 + 1\n```\n\n<!-- livebook:{\"stamp\":\"old\",\"offset\":1} -->\n"

    {:ok, notebook} = Notebook.from_livemd(source)
    cell = Enum.find(notebook.blocks, & &1.executable)

    exported =
      Notebook.to_livemd(notebook,
        outputs: %{cell.id => %{status: :ok, output: "printed\n", result: "2"}}
      )

    refute exported =~ "old"
    assert {:ok, imported} = Notebook.from_livemd(exported)
    assert Enum.any?(imported.blocks, &(&1.kind == :output and &1.source == "printed\n2"))
  end

  test "branch sections are preserved but cannot run with linear evaluation" do
    source =
      "# Test\n\n<!-- livebook:{\"branch_parent_index\":0} -->\n## Branch\n\n```elixir\nbranch_only()\n```\n"

    {:ok, notebook} = Notebook.from_livemd(source)
    refute Enum.any?(notebook.blocks, & &1.executable)
    assert Notebook.to_livemd(notebook) == source
    refute Enum.any?(Notebook.append(notebook, :elixir).blocks, & &1.executable)
  end

  test "fences in multiline comments are not executable" do
    source = "# Test\n\n<!--\n```elixir\nnever_run()\n```\n-->\n"
    {:ok, notebook} = Notebook.from_livemd(source)
    refute Enum.any?(notebook.blocks, & &1.executable)
    assert Notebook.to_livemd(notebook) == source
  end

  test "fenced examples inside raw HTML stay Markdown" do
    for tag <- ["pre", "div"] do
      source = "# Test\n\n<#{tag}>\n```elixir\nnever_run()\n```\n</#{tag}>\n"
      {:ok, notebook} = Notebook.from_livemd(source)
      refute Enum.any?(notebook.blocks, & &1.executable)
      assert Notebook.to_livemd(notebook) == source
    end
  end
end
