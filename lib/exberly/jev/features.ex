defmodule Exberly.Jev.Features do
  @moduledoc """
  Derived measurements for Jev. Trends, growth rates and shares are
  computed here, exactly, so the model classifies facts instead of doing
  arithmetic over raw samples. Nothing here identifies a process: no
  names, pids, modules or functions.
  """

  @doc "Least-squares slope of `{t_seconds, value}` points, per second (nil under 2 points)."
  def slope(points) do
    points = Enum.reject(points, fn {_t, v} -> not is_number(v) end)
    n = length(points)

    if n < 2 do
      nil
    else
      mt = Enum.sum(Enum.map(points, &elem(&1, 0))) / n
      mv = Enum.sum(Enum.map(points, &elem(&1, 1))) / n
      den = Enum.sum(Enum.map(points, fn {t, _} -> (t - mt) * (t - mt) end))

      if den == 0,
        do: nil,
        else:
          Enum.sum(Enum.map(points, fn {t, v} -> (t - mt) * (v - mv) end))
          |> Kernel./(den)
          |> Float.round(2)
    end
  end

  @doc "Change from the first to the last value, in percent of the first."
  def change_pct([first | _] = values) when is_number(first) and first > 0 do
    last = List.last(values)
    if is_number(last), do: Float.round((last - first) / first * 100, 1)
  end

  def change_pct(_), do: nil

  def mean([]), do: nil

  def mean(values) do
    known = Enum.filter(values, &is_number/1)
    if known == [], do: nil, else: Float.round(Enum.sum(known) / length(known), 1)
  end

  def max_of(values), do: values |> Enum.filter(&is_number/1) |> Enum.max(fn -> nil end)

  @doc "Part of a whole, in percent (nil when unknown)."
  def share(part, whole) when is_number(part) and is_number(whole) and whole > 0,
    do: Float.round(part / whole * 100, 1)

  def share(_, _), do: nil

  @doc "How many times `a` is `b` (binaries live off the heap, so this can exceed 1)."
  def ratio(a, b) when is_number(a) and is_number(b) and b > 0, do: Float.round(a / b, 2)
  def ratio(_, _), do: nil

  @doc """
  Where the process stands among all processes: the percentage of
  processes whose value is at least this one ("top 2%").
  """
  def top_pct(values, value) when is_number(value) do
    known = Enum.filter(values, &is_number/1)

    if known == [],
      do: nil,
      else: Float.round(Enum.count(known, &(&1 >= value)) / length(known) * 100, 1)
  end

  def top_pct(_, _), do: nil

  @doc """
  Node context for one process from a list of `%{pid, memory, queue,
  rate, kind}` rows (the process table): its rank and share, and its OTP
  kind. Returns `%{}` when the process is not in the list.
  """
  def node_context(rows, pid) do
    case Enum.find(rows, &(&1.pid == pid)) do
      nil ->
        %{}

      row ->
        total = rows |> Enum.map(& &1.memory) |> Enum.filter(&is_number/1) |> Enum.sum()

        %{
          otp_kind: kind(row[:kind]),
          processes_on_node: length(rows),
          memory_share_of_all_processes_pct: share(row.memory, total),
          memory_rank_top_pct: top_pct(Enum.map(rows, & &1.memory), row.memory),
          queue_rank_top_pct:
            if(row[:queue] && row.queue > 0,
              do: top_pct(Enum.map(rows, & &1[:queue]), row.queue)
            ),
          reductions_rate_rank_top_pct:
            if(row[:rate] && row.rate > 0,
              do: top_pct(Enum.map(rows, & &1[:rate]), row.rate)
            )
        }
    end
  end

  defp kind(k) when k in [:gen_server, :gen_statem, :gen_event, :supervisor], do: k
  defp kind(_), do: :plain_process

  @doc """
  What a process is waiting in, as a category only (never the function):
  the OTP receive loop, a call waiting for another process's reply
  (`GenServer.call`, `gen_statem:call`, ...), hibernation, a sleep, I/O,
  or application code.
  """
  def wait_category(status, _current) when status in [:running, :runnable], do: :running
  def wait_category(:garbage_collecting, _), do: :garbage_collecting
  def wait_category(:suspended, _), do: :suspended
  def wait_category(:exiting, _), do: :exiting
  def wait_category(_status, {:erlang, :hibernate, _}), do: :hibernated
  def wait_category(_status, {:timer, :sleep, _}), do: :sleeping

  # gen:do_call/4 is where every OTP call waits for the reply: not idle
  def wait_category(_status, {:gen, f, _})
      when f in [:do_call, :wait_response, :receive_response],
      do: :call_reply

  def wait_category(_status, {m, _, _})
      when m in [:gen_server, :gen_statem, :gen_event, :gen, :proc_lib, :supervisor, :sys],
      do: :otp_receive_loop

  def wait_category(_status, {m, _, _})
      when m in [:prim_inet, :prim_file, :file_io_server, :gen_tcp, :gen_udp, :inet, :ssl, :io],
      do: :io

  def wait_category(_status, {_m, _, _}), do: :application_code
  def wait_category(_status, _), do: :unknown

  @doc "Every `every`-th item (the last always kept), for a short raw backup series."
  def thin(items, max) when length(items) <= max, do: items

  def thin(items, max) do
    every = ceil(length(items) / max)
    kept = items |> Enum.with_index() |> Enum.filter(fn {_, i} -> rem(i, every) == 0 end)
    kept = Enum.map(kept, &elem(&1, 0))
    if List.last(kept) == List.last(items), do: kept, else: kept ++ [List.last(items)]
  end
end
