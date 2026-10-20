defmodule Exberly.MemoryAdvisor do
  @moduledoc """
  Node memory health check with Jev, for the Memory tab: which kind of
  memory, if any, needs attention. exberly computes, per kind of
  `erlang:memory()`, its size, share of the total, change over the
  observed window and growth per second, plus how close atom, process and
  ETS counts are to their limits and how much the allocators hold beyond
  what is used. Nothing identifies a process, table or module.
  """
  alias Exberly.Jev
  alias Exberly.Jev.Features, as: F

  @min_samples 8
  @min_window_s 14

  @choices %{
    "processes" => %{
      label: "Process memory",
      what:
        "Process heaps are the largest or fastest-growing part: look for the processes that hold or gain the most memory, or long message queues.",
      not_for: "A stable process share with nothing growing."
    },
    "binary" => %{
      label: "Binaries",
      what:
        "Off-heap binaries are large or growing: look for processes holding binary references, which a forced GC may release.",
      not_for: "Small or steady binary memory."
    },
    "ets" => %{
      label: "ETS tables",
      what:
        "ETS memory is large or growing, or the table count nears its limit: look for tables that keep growing.",
      not_for: "Steady ETS memory well below the limit."
    },
    "atoms" => %{
      label: "Atom table",
      what:
        "Atoms keep being created or the count is a large share of the limit: atoms are never collected, so something creates them from data.",
      not_for: "A constant atom count far below the limit."
    },
    "code" => %{
      label: "Loaded code",
      what: "Code memory grows: modules are being loaded or generated repeatedly.",
      not_for: "Constant code size after startup."
    },
    "allocators" => %{
      label: "Allocator overhead",
      what:
        "The allocators hold much more than is used (fragmentation), or other system memory grows while the parts above do not.",
      not_for: "Allocated close to used."
    },
    "no_clear_issue" => %{
      label: "No clear issue",
      what:
        "Every kind is steady and limits are far away: nothing in node memory needs attention in this window.",
      not_for: "Any clear growth, or a limit close to being reached."
    }
  }

  @question %{
    question: "Which kind of memory on this Erlang/Elixir node needs attention first, if any?",
    rules: [
      "Growth figures are per second over observed_window_s; shares and limit usage are percentages.",
      "A large but steady part is less urgent than one that keeps growing.",
      "Null means not measured."
    ]
  }

  def choices, do: @choices

  @doc "The Memory tab view to open for an answer, if it has one."
  def view_for("processes"), do: :processes
  def view_for("binary"), do: :binary
  def view_for("ets"), do: :ets
  def view_for(_), do: nil

  @doc "`{:ready, s}` or `{:collecting, s, needed}` for history points `%{at: ms}`."
  def readiness(history) do
    s = window(history)

    if length(history) >= @min_samples and s >= @min_window_s,
      do: {:ready, s},
      else: {:collecting, s, @min_window_s + 1}
  end

  def analyze(evidence, opts \\ []) do
    with {:ok, answer} <- Jev.ask(evidence, @question, @choices, opts) do
      c = @choices[answer.choice]

      {:ok,
       Map.merge(answer, %{
         title: c.label,
         description: c.what,
         samples: evidence.observed_samples,
         window_s: evidence.observed_window_s,
         view: view_for(answer.choice),
         at: DateTime.utc_now()
       })}
    end
  end

  @doc """
  The state sent to Jev from the latest `snap` (`Exberly.Memory.snapshot/1`)
  and `history` (`%{at: ms, memory: erlang:memory() map}`, oldest first).
  """
  def evidence(snap, history) do
    m = snap.memory
    total = m[:total]
    t0 = with [%{at: at} | _] <- history, do: at, else: (_ -> 0)
    series = fn key -> Enum.map(history, &{(&1.at - t0) / 1000, part(&1.memory, key)}) end

    kinds =
      Map.new([:processes, :binary, :ets, :atom, :code, :other], fn key ->
        values = Enum.map(history, &part(&1.memory, key))

        {key,
         %{
           bytes: part(m, key),
           share_of_total_pct: F.share(part(m, key), total),
           change_over_window_pct: F.change_pct(values),
           growth_bytes_per_s: F.slope(series.(key))
         }}
      end)

    alloc = snap[:alloc]

    %{
      observed_samples: length(history),
      observed_window_s: window(history),
      total_bytes: total,
      total_growth_bytes_per_s: F.slope(series.(:total)),
      kinds: kinds,
      limits: %{
        atoms_used_pct: F.share(snap[:atom_count], snap[:atom_limit]),
        processes_used_pct: F.share(snap[:process_count], snap[:process_limit]),
        ets_tables_used_pct: F.share(snap[:ets_count], snap[:ets_limit]),
        loaded_modules: snap[:module_count]
      },
      allocators:
        if is_map(alloc) do
          %{
            allocated_bytes: alloc[:allocated],
            used_bytes: alloc[:used],
            used_share_of_allocated_pct: F.share(alloc[:used], alloc[:allocated])
          }
        end
    }
  end

  # "other": system memory not in binaries, ETS, code or atoms
  defp part(m, :other),
    do:
      max(
        (m[:system] || 0) - (m[:binary] || 0) - (m[:ets] || 0) - (m[:code] || 0) -
          (m[:atom] || 0),
        0
      )

  defp part(m, key), do: m[key]

  defp window([]), do: 0
  defp window([first | _] = h), do: div(List.last(h).at - first.at, 1000)
end
