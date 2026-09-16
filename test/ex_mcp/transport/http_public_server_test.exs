defmodule ExMCP.Transport.HTTPPublicServerTest do
  @moduledoc """
  Connecting to servers that behave the way ordinary public MCP servers do.

  Each test states a server behaviour that was observed in the field and
  asserts that a client reaches it. The fake server is deliberately plain: it
  answers `initialize` and nothing else, at one path, and it is free to refuse
  anything it did not ask for.
  """

  use ExUnit.Case, async: false

  alias ExMCP.Client

  defmodule PublicServerPlug do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: Map.new(opts)

    @impl true
    def call(conn, opts) do
      {:ok, raw_body, conn} = read_body(conn)
      message = if raw_body == "", do: %{}, else: Jason.decode!(raw_body)
      origin = List.first(get_req_header(conn, "origin"))

      send(
        opts.test_pid,
        {:public_server_request,
         %{path: conn.request_path, origin: origin, method: message["method"]}}
      )

      cond do
        Map.get(opts, :reject_origin, false) and origin != nil ->
          send_resp(conn, 403, "Origin not permitted")

        conn.request_path != opts.mcp_path ->
          send_resp(conn, 404, "Not Found")

        true ->
          respond(conn, message, opts)
      end
    end

    # The server has never heard of the modern discovery method.
    defp respond(conn, %{"method" => "server/discover"}, opts) do
      send_resp(conn, Map.get(opts, :discover_status, 404), "Not Found")
    end

    defp respond(conn, %{"method" => "initialize", "id" => id}, _opts) do
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "fake-public-server", "version" => "1"}
        }
      })
    end

    defp respond(conn, %{"id" => id}, _opts) do
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32601, "message" => "Method not found"}
      })
    end

    # Notifications carry no id.
    defp respond(conn, _message, _opts), do: send_resp(conn, 202, "")

    defp json(conn, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(payload))
    end
  end

  describe "Origin header" do
    test "connects to a server that refuses a self-asserted Origin" do
      port = start_server(mcp_path: "/mcp", reject_origin: true)

      {:ok, client} = start_client("http://127.0.0.1:#{port}/mcp")

      assert_receive {:public_server_request, %{method: "initialize", origin: nil}}
      assert {:ok, %{"name" => "fake-public-server"}} = Client.server_info(client)
    end

    test "sends the Origin header the caller configured" do
      port = start_server(mcp_path: "/mcp")

      {:ok, _client} =
        start_client("http://127.0.0.1:#{port}/mcp",
          security: %{origin: "https://app.example.com"}
        )

      assert_receive {:public_server_request,
                      %{method: "initialize", origin: "https://app.example.com"}}
    end
  end

  describe "endpoint path" do
    test "reaches a server that serves MCP at the root" do
      port = start_server(mcp_path: "/")

      {:ok, client} = start_client("http://127.0.0.1:#{port}/")

      assert_receive {:public_server_request, %{method: "initialize", path: "/"}}
      assert {:ok, %{"name" => "fake-public-server"}} = Client.server_info(client)
    end

    test "still defaults to /mcp/v1 for a URL with no path" do
      port = start_server(mcp_path: "/mcp/v1")

      {:ok, client} = start_client("http://127.0.0.1:#{port}")

      assert_receive {:public_server_request, %{method: "initialize", path: "/mcp/v1"}}
      assert {:ok, %{"name" => "fake-public-server"}} = Client.server_info(client)
    end
  end

  describe "era probe refused at the HTTP level" do
    for status <- [400, 403, 404, 405, 415] do
      test "an HTTP #{status} on server/discover still leads to initialize" do
        port = start_server(mcp_path: "/mcp", discover_status: unquote(status))

        {:ok, client} =
          start_client("http://127.0.0.1:#{port}/mcp",
            protocol_mode: :prefer_modern,
            protocol_version: nil,
            reset_era_cache: true
          )

        assert_receive {:public_server_request, %{method: "server/discover"}}
        assert_receive {:public_server_request, %{method: "initialize"}}
        assert {:ok, "2025-11-25"} = Client.negotiated_version(client)
      end
    end

    test "an HTTP 401 on server/discover is not a reason to downgrade" do
      Process.flag(:trap_exit, true)
      port = start_server(mcp_path: "/mcp", discover_status: 401)

      assert {:error, _reason} =
               start_client("http://127.0.0.1:#{port}/mcp",
                 protocol_mode: :prefer_modern,
                 protocol_version: nil,
                 reset_era_cache: true
               )

      assert_receive {:public_server_request, %{method: "server/discover"}}
      refute_receive {:public_server_request, %{method: "initialize"}}
    end
  end

  defp start_client(url, overrides \\ []) do
    opts =
      [
        transport: :http,
        url: url,
        protocol_mode: :legacy_only,
        protocol_version: "2025-11-25",
        use_sse: false,
        health_check_interval: nil
      ]
      |> Keyword.merge(overrides)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Client.start_link(opts) do
      {:ok, client} ->
        on_exit(fn ->
          try do
            if Process.alive?(client), do: Client.stop(client)
          catch
            :exit, _reason -> :ok
          end
        end)

        {:ok, client}

      error ->
        error
    end
  end

  defp start_server(opts) do
    port = free_port()
    ref = {:http_public_server_test, System.unique_integer([:positive])}

    {:ok, _pid} =
      Plug.Cowboy.http(
        PublicServerPlug,
        Keyword.put(opts, :test_pid, self()),
        ip: {127, 0, 0, 1},
        port: port,
        ref: ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ref)
      catch
        :exit, _reason -> :ok
      end
    end)

    port
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
