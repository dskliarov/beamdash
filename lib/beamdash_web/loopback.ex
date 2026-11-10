defmodule BeamdashWeb.Loopback do
  @moduledoc """
  Whether a request comes from this computer. The client address, Host and
  Origin must all be loopback, so a web page open in the browser cannot reach
  the local endpoints (DNS rebinding).
  """

  import Plug.Conn

  @loopback_hosts ~w(localhost 127.0.0.1 ::1 [::1])

  def allowed?(conn) do
    loopback_client?(conn.remote_ip) and loopback_host?(conn.host) and origin_ok?(conn)
  end

  defp loopback_client?({127, _, _, _}), do: true
  defp loopback_client?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_client?(_address), do: false

  defp loopback_host?(host) when is_binary(host), do: String.downcase(host) in @loopback_hosts
  defp loopback_host?(_host), do: false

  defp origin_ok?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> loopback_host?(URI.parse(origin).host)
      _ -> false
    end
  end
end
