defmodule Beamdash.Plugins.Fetch do
  @moduledoc """
  Gets a plugin's own source, from a `Beamdash.Plugins.Spec`, into a
  directory. Its dependencies are not fetched.

    * **Git:** `git clone` into `<dest>/src`. A tag or branch gets a shallow
      clone with `--branch`; a `ref:` gets a full clone and a checkout.
      `resolved` is the commit (`git rev-parse HEAD`).
    * **Hex:** the requirement is resolved to the highest matching release
      listed by `mix hex.info`, then `mix hex.package fetch --unpack` puts it
      in `<dest>/src`. `resolved` is the version. An exact requirement
      (`"== 0.1.0"`) skips the listing, so it also reaches releases that
      `hex.info` no longer lists. The mix commands go through
      `config :beamdash, :plugins_hex_cmd` (a function from the argument list,
      and optionally the private working directory, to `{output, status}`),
      which tests replace. mix runs in a fresh 0700 directory, never in a
      shared one, because it would evaluate a `./mix.exs` found there.
    * **Path:** nothing is copied. The folder must exist, hold a `mix.exs`
      and not be inside the plugins dir (symbolic links resolved), where
      beamdash deletes things; it is the source, and `resolved` is its path.

  External commands run as ports with a timeout from
  `config :beamdash, :plugins_fetch_timeout` (default 120 000 ms). A command
  that times out is killed together with its process group. Git is started without a shell,
  the URL and destination come after `--`, and `GIT_TERMINAL_PROMPT=0`
  stops it asking for credentials.
  """

  alias Beamdash.Plugins.{Build, Spec}

  @default_timeout 120_000
  @max_output 1_000
  @exact_re ~r/\A(?:==\s*)?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)\z/

  @doc "Fetches the plugin described by `spec` into `dest_dir`."
  @spec fetch(Spec.t(), Path.t()) ::
          {:ok, %{src: Path.t(), resolved: String.t()}} | {:error, String.t()}
  def fetch(%{source: :git} = spec, dest_dir) do
    src = Path.join(dest_dir, "src")

    with :ok <- mkdir(dest_dir),
         :ok <- clone(spec, src),
         :ok <- checkout(spec, src),
         {:ok, commit} <- rev_parse(src) do
      {:ok, %{src: src, resolved: commit}}
    end
  end

  def fetch(%{source: :hex} = spec, dest_dir) do
    cwd = Path.join(dest_dir, ".mix-#{System.unique_integer([:positive])}")

    try do
      with :ok <- mkdir(dest_dir),
           {:ok, cwd} <- private_dir(cwd),
           do: fetch_hex(spec, Path.join(dest_dir, "src"), cwd)
    after
      File.rm_rf(cwd)
    end
  end

  def fetch(%{source: :path, path: path}, _dest_dir) do
    cond do
      not File.dir?(path) ->
        {:error, "the folder #{path} does not exist"}

      Build.in_plugins_dir?(path) ->
        {:error,
         "the folder #{path} is inside the plugins folder #{Build.plugins_dir()}, " <>
           "where beamdash deletes what it keeps: move it somewhere else"}

      true ->
        with :ok <- has_mix_exs(path, "the folder #{path}"),
             do: {:ok, %{src: path, resolved: path}}
    end
  end

  defp fetch_hex(spec, src, cwd) do
    with {:ok, version} <- resolve_version(spec, cwd),
         :ok <- hex_fetch(spec.package, version, src, cwd),
         :ok <- has_mix_exs(src, "the Hex package #{spec.package} #{version}") do
      {:ok, %{src: src, resolved: version}}
    end
  end

  defp has_mix_exs(dir, what) do
    if File.regular?(Path.join(dir, "mix.exs")),
      do: :ok,
      else: {:error, "#{what} has no mix.exs"}
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  ## Git

  defp clone(%{url: url, ref: ref}, src) do
    args =
      case ref do
        {:ref, _} -> ["clone", "--", url, src]
        {_, name} -> ["clone", "--depth", "1", "--branch", name, "--", url, src]
        nil -> ["clone", "--depth", "1", "--", url, src]
      end

    with {:ok, _} <- git(args, "clone"), do: :ok
  end

  defp checkout(%{ref: {:ref, ref}}, src) do
    with {:ok, _} <- git(["-C", src, "checkout", "-q", ref, "--"], "checkout"), do: :ok
  end

  defp checkout(_spec, _src), do: :ok

  defp rev_parse(src) do
    with {:ok, out} <- git(["-C", src, "rev-parse", "HEAD"], "rev-parse") do
      commit = String.trim(out)

      if Regex.match?(~r/\A[0-9a-f]{40,64}\z/, commit),
        do: {:ok, commit},
        else: {:error, "git rev-parse HEAD gave #{inspect(clip(out))}"}
    end
  end

  # A fresh directory only this user can enter, for mix to run in: mix reads
  # a ./mix.exs from its working directory, so that must not be a shared one.
  defp private_dir(dir) do
    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    else
      {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  # git is run without a shell. `ext::` transports (which run commands) are
  # off, and neither git nor ssh may prompt: ssh runs in batch mode (unless
  # the user set GIT_SSH_COMMAND or GIT_SSH) and the askpass helpers fail.
  defp git_env do
    no = System.find_executable("false") || "false"
    base = [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_ASKPASS", no}, {"SSH_ASKPASS", no}]

    if System.get_env("GIT_SSH_COMMAND") || System.get_env("GIT_SSH"),
      do: base,
      else: [{"GIT_SSH_COMMAND", "ssh -o BatchMode=yes"} | base]
  end

  defp git(args, what) do
    case System.find_executable("git") do
      nil ->
        {:error, "git not found on PATH"}

      exe ->
        case run_cmd(exe, ["-c", "protocol.ext.allow=never" | args], env: git_env()) do
          {:ok, {out, 0}} -> {:ok, out}
          {:ok, {out, _}} -> {:error, "git #{what} failed: #{clip(out)}"}
          {:error, :timeout} -> {:error, "git timed out after #{show_timeout()}"}
          {:error, reason} -> {:error, "git could not run: #{inspect(reason)}"}
        end
    end
  end

  ## Hex

  defp resolve_version(%{package: package, requirement: req}, cwd) do
    case Regex.run(@exact_re, req) do
      [_, version] -> {:ok, version}
      nil -> list_version(package, req, cwd)
    end
  end

  defp list_version(package, req, cwd) do
    with {:ok, out} <- hex(["hex.info", package], cwd) do
      case parse_releases(out) do
        [] ->
          {:error, "could not read the releases of #{package} from mix hex.info"}

        listed ->
          matching = Enum.filter(listed, &Version.match?(&1, req))

          case Enum.sort(matching, Version) do
            [] ->
              {:error,
               "no release of #{package} listed by Hex (#{listed |> Enum.map(&to_string/1) |> Enum.join(", ")}) " <>
                 "matches #{req}. The matching version may be older than those Hex listed: " <>
                 ~s|give an exact version, e.g. {:#{package}, "== 0.1.0"}|}

            sorted ->
              {:ok, sorted |> List.last() |> to_string()}
          end
      end
    end
  end

  # The releases listed by `mix hex.info`. Hex 2.5 and later print
  # "Recent releases:" and then one "  0.11.1 (2026-06-12)" per line, up to a
  # blank line; older Hex printed them on one line, comma separated, after
  # "Releases: ". Either may end with "..." and mark a release " (retired)";
  # retired releases are skipped. Colour codes are stripped first.
  defp parse_releases(output) do
    lines =
      Regex.replace(~r/\e\[[0-9;]*m/, output, "")
      |> String.split(["\r\n", "\n"])
      |> Enum.drop_while(&(not Regex.match?(~r/\A\s*(?:Recent releases|Releases):/, &1)))

    entries =
      case lines do
        [] ->
          []

        [header | rest] ->
          [_, inline] = String.split(header, ":", parts: 2)

          if String.trim(inline) == "",
            do: Enum.take_while(rest, &(String.trim(&1) != "")),
            else: String.split(inline, ",")
      end

    Enum.flat_map(entries, &release_version/1)
  end

  defp release_version(entry) do
    with [text | notes] <- String.split(entry),
         false <- "(retired)" in notes,
         {:ok, version} <- Version.parse(text) do
      [version]
    else
      _ -> []
    end
  end

  defp hex_fetch(package, version, src, cwd) do
    args = ["hex.package", "fetch", package, version, "--unpack", "--output", src]
    with {:ok, _} <- hex(args, cwd), do: :ok
  end

  # A configured runner takes the args (arity 1) or the args and the private
  # working directory (arity 2).
  defp hex(args, cwd) do
    {out, status} =
      case Application.get_env(:beamdash, :plugins_hex_cmd) do
        nil -> default_hex_cmd(args, cwd)
        runner when is_function(runner, 2) -> runner.(args, cwd)
        runner when is_function(runner, 1) -> runner.(args)
      end

    cond do
      hex_missing?(out) -> {:error, "Hex is not installed: run `mix local.hex`"}
      status == 0 -> {:ok, out}
      true -> {:error, failure(out, "mix #{Enum.at(args, 0)}", status)}
    end
  end

  # Without Hex, mix asks "Shall I install Hex?"; `default_hex_cmd/2`
  # answers no, so mix then says the hex task could not be found.
  defp hex_missing?(out) do
    String.contains?(out, "Shall I install Hex?") or
      Regex.match?(~r/The task "hex\.[a-z_.]+" could not be found/, out)
  end

  defp failure(out, what, status) do
    case String.trim(out) do
      "" -> "#{what} failed (exit status #{status})"
      text -> clip(text)
    end
  end

  @doc """
  Runs `mix` with `args` for Hex plugins and returns `{output, status}`.

  It runs in `cwd`, which must be a fresh directory only this user can
  write: mix would evaluate a `./mix.exs` found there. `fetch/2` passes a new
  0700 directory inside its destination. Without `cwd`, a new 0700
  directory is made under the system temp dir and deleted afterwards.
  """
  @spec default_hex_cmd([String.t()], Path.t() | nil) :: {String.t(), non_neg_integer()}
  def default_hex_cmd(args, cwd \\ nil)

  def default_hex_cmd(args, nil) do
    dir = Path.join(System.tmp_dir!(), "beamdash-mix-#{System.unique_integer([:positive])}")

    case private_dir(dir) do
      {:ok, dir} ->
        try do
          default_hex_cmd(args, dir)
        after
          File.rm_rf(dir)
        end

      {:error, message} ->
        {message, 126}
    end
  end

  def default_hex_cmd(args, cwd) do
    case System.find_executable("mix") do
      nil ->
        {"mix not found on PATH (needed for Hex plugins)", 127}

      mix ->
        # Without Hex, mix asks whether to install it and waits on stdin:
        # the "n" answers that, so it fails at once instead of timing out.
        opts = [env: [{"MIX_ENV", "prod"}], cd: cwd, input: "n\n"]

        case run_cmd(mix, args, opts) do
          {:ok, result} -> result
          {:error, :timeout} -> {"mix timed out after #{show_timeout()}", 124}
          {:error, reason} -> {"mix could not run: #{inspect(reason)}", 126}
        end
    end
  end

  ## Running commands

  @doc false
  # Runs `exe args` as a port and collects its output (stderr included)
  # until it exits. Returns `{:ok, {output, status}}`, or `{:error, :timeout}`
  # after killing it, or `{:error, reason}` when it can't be started.
  # Options: `:env` ([{name, value}]), `:cd`, and `:input` (written to
  # its stdin once it starts).
  #
  # erts starts a port program as the leader of a new session and process
  # group (its pgid is its os_pid), so on timeout the whole group is killed:
  # git's children (git-remote-*, ssh, ...) go too. A child that starts its
  # own session would escape; that is not something git or mix do.
  @spec run_cmd(String.t(), [String.t()], keyword()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, :timeout | term()}
  def run_cmd(exe, args, opts) do
    env = for {k, v} <- Keyword.get(opts, :env, []), do: {to_charlist(k), to_charlist(v)}

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, :hide, args: args, env: env] ++
        if(opts[:cd], do: [cd: opts[:cd]], else: [])

    port = Port.open({:spawn_executable, exe}, port_opts)
    if input = opts[:input], do: send_input(port, input)
    collect(port, now() + timeout(), [])
  rescue
    error in ErlangError -> {:error, error.original}
  end

  # The program may already have exited and closed the port.
  defp send_input(port, input) do
    Port.command(port, input)
  rescue
    ArgumentError -> :ok
  end

  defp collect(port, deadline, acc) do
    receive do
      {^port, {:data, data}} ->
        collect(port, deadline, [acc | data])

      {^port, {:exit_status, status}} ->
        {:ok, {IO.iodata_to_binary(acc), status}}
    after
      max(deadline - now(), 0) ->
        kill(port)
        {:error, :timeout}
    end
  end

  # Kills the OS process and its process group (the port's close alone
  # leaves them running), then drops any messages the port sent meanwhile.
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        pid = Integer.to_string(os_pid)
        System.cmd("kill", ["-KILL", "--", "-" <> pid], stderr_to_stdout: true)
        System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)

      nil ->
        :ok
    end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp timeout, do: Application.get_env(:beamdash, :plugins_fetch_timeout, @default_timeout)

  defp show_timeout do
    ms = timeout()
    if ms >= 1000, do: "#{div(ms, 1000)} s", else: "#{ms} ms"
  end

  defp clip(text) do
    text = String.trim(text)

    if String.length(text) > @max_output,
      do: String.slice(text, 0, @max_output) <> "...",
      else: text
  end
end
