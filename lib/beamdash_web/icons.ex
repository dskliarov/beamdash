defmodule BeamdashWeb.Icons do
  @moduledoc """
  Small inline SVG icons marking a process's OTP behaviour. Each kind has
  its own shape as well as its own colour, so they tell apart without
  colour too.
  """
  use Phoenix.Component

  @marked [:gen_server, :gen_statem, :supervisor]

  @doc "The kinds of process that get an icon, in legend order."
  def marked_kinds, do: @marked

  attr :kind, :atom, required: true

  @doc "The icon for a process of `kind`, or nothing if that kind is not marked."
  def kind(%{kind: :gen_server} = assigns), do: gen_server(assigns)
  def kind(%{kind: :gen_statem} = assigns), do: gen_statem(assigns)
  def kind(%{kind: :supervisor} = assigns), do: supervisor(assigns)
  def kind(assigns), do: ~H""

  attr :rest, :global

  @doc "Marks a process that runs the gen_server behaviour."
  def gen_server(assigns) do
    ~H"""
    <svg
      class="kind-icon icon-gen-server"
      viewBox="0 0 16 16"
      width="14"
      height="14"
      role="img"
      aria-label="gen_server"
      {@rest}
    >
      <title>gen_server</title>
      <rect x="1.5" y="2" width="13" height="5" rx="1.5" />
      <rect x="1.5" y="9" width="13" height="5" rx="1.5" />
      <circle cx="4.5" cy="4.5" r="1" class="dot" />
      <circle cx="4.5" cy="11.5" r="1" class="dot" />
    </svg>
    """
  end

  attr :rest, :global

  @doc "Marks a process that runs the gen_statem behaviour (Erlang or Elixir)."
  def gen_statem(assigns) do
    ~H"""
    <svg
      class="kind-icon icon-gen-statem"
      viewBox="0 0 16 16"
      width="14"
      height="14"
      role="img"
      aria-label="gen_statem"
      {@rest}
    >
      <title>gen_statem</title>
      <circle cx="3" cy="10" r="2.2" class="dot" />
      <circle cx="13" cy="10" r="2.2" />
      <path d="M5.8 10h4.4M8.6 8.3l1.7 1.7-1.7 1.7" />
      <path d="M12.4 7.4Q8 1.2 3.6 7.4" />
    </svg>
    """
  end

  attr :rest, :global

  @doc "Marks a supervisor (including supervisor_bridge and DynamicSupervisor)."
  def supervisor(assigns) do
    ~H"""
    <svg
      class="kind-icon icon-supervisor"
      viewBox="0 0 16 16"
      width="14"
      height="14"
      role="img"
      aria-label="supervisor"
      {@rest}
    >
      <title>supervisor</title>
      <path d="M8 5.5v2.5M3 11V8h10v3M8 8v3" />
      <circle cx="8" cy="3.5" r="2" class="dot" />
      <circle cx="3" cy="12.5" r="1.6" />
      <circle cx="8" cy="12.5" r="1.6" />
      <circle cx="13" cy="12.5" r="1.6" />
    </svg>
    """
  end
end
