defmodule Beamdash.Notebook do
  @moduledoc "LiveMarkdown notebook editing with lossless preservation of untouched blocks."
  @metadata ~r/<!--\s*livebook:((?:(?!-->).)*)-->\s*\z/s
  @languages %{
    "elixir" => :elixir,
    "erlang" => :erlang,
    "python" => :python,
    "pyproject.toml" => :python_config
  }

  def new do
    {:ok, notebook} =
      from_livemd("# Untitled notebook\n\n## Section\n\n```elixir\nNode.self()\n```\n")

    notebook
  end

  def from_livemd(source) when is_binary(source) do
    cond do
      byte_size(source) > 2 * 1024 * 1024 ->
        {:error, "Notebook exceeds the 2 MiB limit."}

      not String.valid?(source) ->
        {:error, "Notebook must be UTF-8 text."}

      true ->
        blocks = scan(String.split(source, ~r/(?<=\n)/, trim: true), "", []) |> Enum.reverse()

        title =
          Enum.find_value(blocks, "Untitled notebook", fn block ->
            if block.kind == :markdown do
              case Regex.run(~r/^#\s+(.+?)\r?$/m, block.source) do
                [_, title] -> title
                _ -> nil
              end
            end
          end)

        warnings =
          if Enum.any?(blocks, &(&1.kind == :code and not &1.executable)),
            do: [
              "Smart cells, Python and other Livebook runtime features are preserved but cannot be executed here."
            ],
            else: []

        warnings =
          if String.contains?(source, "\"stamp\""),
            do:
              warnings ++
                ["Notebook signatures are not verified here; editing removes the old signature."],
            else: warnings

        branched =
          Regex.scan(~r/<!--\s*livebook:((?:(?!-->).)*)-->/s, source)
          |> Enum.any?(fn [_, json] ->
            case Jason.decode(String.trim(json)) do
              {:ok, metadata} when is_map(metadata) ->
                Map.has_key?(metadata, "branch_parent_index")

              _ ->
                false
            end
          end)

        blocks = if branched, do: Enum.map(blocks, &%{&1 | executable: false}), else: blocks

        warnings =
          if branched,
            do:
              warnings ++
                [
                  "Branch sections are preserved, but execution is disabled because this runtime uses linear sessions."
                ],
            else: warnings

        {:ok,
         %{title: title, blocks: blocks, warnings: warnings, changed: false, blocked: branched}}
    end
  end

  def to_livemd(notebook, opts \\ []) do
    outputs = Keyword.get(opts, :outputs, %{})
    source = render_blocks(notebook.blocks, outputs)

    if notebook.changed or map_size(outputs) > 0 do
      Regex.replace(~r/<!--\s*livebook:((?:(?!-->).)*)-->/s, source, fn all, json ->
        case Jason.decode(String.trim(json)) do
          {:ok, %{"stamp" => _}} -> ""
          _ -> all
        end
      end)
    else
      source
    end
  end

  defp render_blocks([], _), do: ""

  defp render_blocks([block | rest], outputs) do
    case Map.get(outputs, block.id) do
      %{status: status, output: output, result: result} when status in [:ok, :error] ->
        rest =
          Enum.drop_while(
            rest,
            &(&1.kind == :output or (&1.kind == :markdown and String.trim(&1.source) == ""))
          )

        text =
          output <>
            if(output != "" and not String.ends_with?(output, "\n"), do: "\n", else: "") <> result

        size =
          Regex.scan(~r/`+/, text)
          |> Enum.map(fn [run] -> String.length(run) end)
          |> Enum.max(fn -> 2 end)

        fence = String.duplicate("`", max(size + 1, 3))

        render_block(block) <>
          "\n<!-- livebook:{\"output\":true} -->\n\n" <>
          fence <> "\n" <> text <> "\n" <> fence <> "\n\n" <> render_blocks(rest, outputs)

      _ ->
        render_block(block) <> render_blocks(rest, outputs)
    end
  end

  def rename(notebook, title) do
    title = title |> String.replace(~r/\R/, " ") |> String.trim()
    title = if title == "", do: "Untitled notebook", else: title

    case Enum.find(
           notebook.blocks,
           &(&1.kind == :markdown and Regex.match?(~r/^#\s+.+$/m, &1.source))
         ) do
      nil ->
        notebook

      block ->
        source =
          Regex.replace(~r/^#\s+.+$/m, block.source, fn _ -> "# " <> title end, global: false)

        %{update(notebook, block.id, source, nil) | title: title}
    end
  end

  def update(notebook, id, source, _language) do
    case Enum.find_index(notebook.blocks, &(&1.id == id)) do
      nil ->
        notebook

      index ->
        block = Enum.at(notebook.blocks, index)

        if block.source == source or block.kind == :output or
             block.metadata["livebook_object"] == "smart_cell" do
          notebook
        else
          blocks = List.update_at(notebook.blocks, index, &%{&1 | source: source})
          {before, after_cell} = Enum.split(blocks, index + 1)

          after_cell =
            if block.kind == :code,
              do:
                Enum.drop_while(
                  after_cell,
                  &(&1.kind == :output or (&1.kind == :markdown and String.trim(&1.source) == ""))
                ),
              else: after_cell

          %{notebook | blocks: before ++ after_cell, changed: true}
        end
    end
  end

  def append(notebook, kind) when kind in [:elixir, :erlang, :markdown, :section] do
    source =
      case kind do
        :markdown -> "<!-- livebook:{\"break_markdown\":true} -->\n\nWrite Markdown here.\n"
        :section -> "## New section\n"
        language -> "```#{language}\n\n```\n"
      end

    {:ok, addition} = from_livemd(source)

    addition =
      if notebook.blocked,
        do: %{addition | blocks: Enum.map(addition.blocks, &%{&1 | executable: false})},
        else: addition

    blocks = notebook.blocks ++ [block(:markdown, "\n\n", "\n\n")] ++ addition.blocks
    %{notebook | blocks: blocks, changed: true}
  end

  def remove(notebook, id) do
    index = Enum.find_index(notebook.blocks, &(&1.id == id))

    if index do
      {before, [_ | rest]} = Enum.split(notebook.blocks, index)

      rest =
        Enum.drop_while(
          rest,
          &(&1.kind == :output or (&1.kind == :markdown and String.trim(&1.source) == ""))
        )

      %{notebook | blocks: before ++ rest, changed: true}
    else
      notebook
    end
  end

  defp scan([], markdown, blocks), do: flush(markdown, blocks)

  defp scan([line | lines], markdown, blocks) do
    if break_markdown?(line) do
      scan(lines, line, flush(markdown, blocks))
    else
      scan_comment(line, lines, markdown, blocks)
    end
  end

  defp break_markdown?(line) do
    with [_, json] <- Regex.run(~r/^\s*<!--\s*livebook:(.*?)-->\s*$/, line),
         {:ok, %{"break_markdown" => true}} <- Jason.decode(String.trim(json)) do
      true
    else
      _ -> false
    end
  end

  defp scan_comment(line, lines, markdown, blocks) do
    if Regex.match?(~r/^ {0,3}<!--/, line) and not String.contains?(line, "-->") do
      {comment, rest} = Enum.split_while(lines, &(not String.contains?(&1, "-->")))

      case rest do
        [ending | rest] -> scan(rest, [markdown, line, Enum.join(comment), ending], blocks)
        [] -> flush([markdown, line, Enum.join(comment)], blocks)
      end
    else
      scan_line(line, lines, markdown, blocks)
    end
  end

  defp scan_line(line, lines, markdown, blocks) do
    case html_block(line) do
      nil ->
        scan_fence(line, lines, markdown, blocks)

      ending ->
        if ending != :blank and Regex.match?(ending, line) do
          scan(lines, [markdown, line], blocks)
        else
          {html, rest} = take_html(lines, ending, [line])
          scan(rest, [markdown, html], blocks)
        end
    end
  end

  defp html_block(line) do
    case Regex.run(~r/^ {0,3}<\/?([a-z][a-z0-9-]*)(?:\s|\/?>)/i, line) do
      [_, tag] ->
        tag = String.downcase(tag)

        cond do
          tag in ~w(pre script style textarea) ->
            Regex.compile!("</" <> tag <> "\\s*>", "i")

          tag in ~w(address article aside base blockquote body caption center col colgroup dd details dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr html iframe legend li link main menu menuitem nav noframes ol optgroup option p param search section summary table tbody td tfoot th thead title tr track ul) ->
            :blank

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp take_html([], _, lines), do: {Enum.reverse(lines), []}

  defp take_html([line | rest], ending, lines) do
    if (ending == :blank and String.trim(line) == "") or
         (ending != :blank and Regex.match?(ending, line)) do
      {Enum.reverse([line | lines]), rest}
    else
      take_html(rest, ending, [line | lines])
    end
  end

  defp scan_fence(line, lines, markdown, blocks) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})([^\r\n]*)\r?\n?$/, line) do
      [_, fence, info] ->
        case take_fence(lines, fence, []) do
          {:ok, body, closing, rest} ->
            {prefix, annotations, metadata} = trailing_metadata(markdown)
            info = String.trim(info)
            language = Map.get(@languages, info)
            recognized = language != nil or metadata["output"] == true or info == "output"

            if recognized and metadata["force_markdown"] != true do
              blocks = flush(prefix, blocks)
              kind = if metadata["output"] == true or info == "output", do: :output, else: :code
              raw = annotations <> line <> body <> closing

              code =
                block(kind, trim_newline(body), raw)
                |> Map.merge(%{
                  language: language,
                  info: info,
                  prefix: annotations,
                  fence: fence,
                  metadata: metadata,
                  executable:
                    kind == :code and language in [:elixir, :erlang] and
                      metadata["livebook_object"] != "smart_cell"
                })

              scan(rest, "", [code | blocks])
            else
              scan(rest, [markdown, line, body, closing], blocks)
            end

          :unclosed ->
            flush([markdown, line, Enum.join(lines)], blocks)
        end

      _ ->
        scan(lines, [markdown, line], blocks)
    end
  end

  defp take_fence([], _, _), do: :unclosed

  defp take_fence([line | rest], fence, body) do
    char = String.first(fence)

    if Regex.match?(
         Regex.compile!(
           "^ {0,3}" <>
             Regex.escape(char) <>
             "{" <> Integer.to_string(String.length(fence)) <> ",}[ \\t]*\\r?\\n?$"
         ),
         line
       ) do
      {:ok, body |> Enum.reverse() |> Enum.join(), line, rest}
    else
      take_fence(rest, fence, [line | body])
    end
  end

  defp trailing_metadata(text), do: trailing_metadata(IO.iodata_to_binary(text), "", %{})

  defp trailing_metadata(text, annotations, data) do
    case Regex.run(@metadata, text, return: :index) do
      [{start, _}, {json_start, json_size}] ->
        json = binary_part(text, json_start, json_size)

        case Jason.decode(String.trim(json)) do
          {:ok, metadata} when is_map(metadata) ->
            trailing_metadata(
              binary_part(text, 0, start),
              binary_part(text, start, byte_size(text) - start) <> annotations,
              Map.merge(metadata, data)
            )

          _ ->
            {text, annotations, data}
        end

      _ ->
        {text, annotations, data}
    end
  end

  defp flush(text, blocks) do
    case IO.iodata_to_binary(text) do
      "" -> blocks
      binary -> [block(:markdown, binary, binary) | blocks]
    end
  end

  defp block(kind, source, raw),
    do: %{
      id: "cell-#{System.unique_integer([:positive, :monotonic])}",
      kind: kind,
      source: source,
      original: source,
      raw: raw,
      metadata: %{},
      language: nil,
      executable: false
    }

  defp trim_newline(text), do: Regex.replace(~r/\r?\n\z/, text, "")
  defp render_block(%{source: source, original: source, raw: raw}), do: raw
  defp render_block(%{kind: :markdown, source: source}), do: source <> "\n\n"

  defp render_block(block) do
    size =
      Regex.scan(~r/`+/, block.source)
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 2 end)

    fence = String.duplicate("`", max(size + 1, 3))
    block.prefix <> fence <> block.info <> "\n" <> block.source <> "\n" <> fence <> "\n"
  end

  @doc "Renders Markdown with a restricted tag and URL allowlist."
  def markdown_html(source) do
    {_, ast, _} = EarmarkParser.as_ast(source)
    ast |> Enum.map(&html/1) |> IO.iodata_to_binary()
  end

  defp html(text) when is_binary(text),
    do: Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()

  defp html({:comment, _, _, _}), do: ""

  defp html({tag, attrs, children, _})
       when tag in ~w(h1 h2 h3 h4 h5 h6 p strong em del ul ol li blockquote pre code table thead tbody tr th td hr br a) do
    attributes =
      if tag == "a" do
        href = Enum.find_value(attrs, fn {key, value} -> if key == "href", do: value end)

        if is_binary(href) and Regex.match?(~r/\A(?:https?:\/\/|mailto:|#)/i, href),
          do: [" href=\"", html(href), "\" rel=\"noopener noreferrer\""],
          else: []
      else
        []
      end

    ["<", tag, attributes, ">", Enum.map(children, &html/1), "</", tag, ">"]
  end

  defp html({_, _, children, _}), do: Enum.map(children, &html/1)
  defp html(_), do: ""
end
