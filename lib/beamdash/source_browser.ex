defmodule Beamdash.SourceBrowser do
  @moduledoc "Local source-file navigation and bounded reads for the module editor."
  @max_bytes 2 * 1024 * 1024

  def open(path) do
    path = Path.expand(path)
    browser = %{path: path, subdirs: [], files: [], error: nil}

    case File.ls(path) do
      {:ok, names} ->
        {dirs, files} =
          names
          |> Enum.sort()
          |> Enum.split_with(&File.dir?(Path.join(path, &1)))

        files = Enum.filter(files, &(source_file?(&1) and File.regular?(Path.join(path, &1))))
        %{browser | subdirs: dirs, files: files}

      {:error, reason} ->
        %{browser | error: "Cannot open folder: #{:file.format_error(reason)}"}
    end
  end

  def load(%{files: files, path: dir}, name) do
    if name in files and Path.basename(name) == name and File.regular?(Path.join(dir, name)) do
      path = Path.join(dir, name)

      case File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
        {:ok, text} when is_binary(text) and byte_size(text) <= @max_bytes ->
          if String.valid?(text),
            do: {:ok, %{path: path, text: text, language: language(path)}},
            else: {:error, "The selected file is not valid UTF-8 text."}

        {:ok, :eof} ->
          {:ok, %{path: path, text: "", language: language(path)}}

        {:ok, text} when is_binary(text) ->
          {:error, "The selected source exceeds the 2 MiB limit."}

        {:ok, {:error, reason}} ->
          {:error, "Cannot read source: #{:file.format_error(reason)}"}

        {:error, reason} ->
          {:error, "Cannot open source: #{:file.format_error(reason)}"}
      end
    else
      {:error, "Choose a source file from the current folder."}
    end
  end

  defp source_file?(name), do: Path.extname(name) in [".ex", ".exs", ".erl"]
  defp language(path), do: if(Path.extname(path) == ".erl", do: "erlang", else: "elixir")
end
