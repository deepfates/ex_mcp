defmodule ExMCP.Client.CallerOwnedRequestTest do
  use ExUnit.Case, async: true

  import ExMCP.TestHelpers, only: [wait_until: 1]

  alias ExMCP.Client

  defmodule RecordingTransport do
    @behaviour ExMCP.Transport

    @impl true
    def connect(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def send_message(message, state) do
      request = Jason.decode!(message)
      send(state.test_pid, {:outbound_mcp, request})

      case request do
        %{"method" => "initialize", "id" => id} ->
          response = %{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "caller-owned-test", "version" => "1"}
            }
          }

          {:ok, state, Jason.encode!(response)}

        _request_or_notification ->
          {:ok, state}
      end
    end

    @impl true
    def receive_message(state), do: receive_message(state, 5_000)

    def receive_message(state, timeout) do
      receive do
        {:transport_response, response} -> {:ok, response, state}
      after
        timeout -> {:error, {:timeout_error, :receive_timeout}}
      end
    end

    @impl true
    def connected?(_state), do: true

    @impl true
    def close(_state), do: :ok
  end

  setup do
    {:ok, client} =
      Client.start_link(
        transport: RecordingTransport,
        test_pid: self(),
        protocol_mode: :legacy_only,
        reconnect: false,
        health_check_interval: 60_000
      )

    assert_receive {:outbound_mcp, %{"method" => "initialize"}}
    assert_receive {:outbound_mcp, %{"method" => "notifications/initialized"}}

    on_exit(fn ->
      try do
        GenServer.stop(client)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, client: client}
  end

  test "caller death retires the request, notifies the server, and leaves the client usable", %{
    client: client
  } do
    task = Task.async(fn -> Client.call_tool(client, "slow", %{}, timeout: 30_000) end)

    assert_receive {:outbound_mcp, %{"method" => "tools/call", "id" => request_id}}
    assert map_size(:sys.get_state(client).pending_caller_monitors) == 1

    Task.shutdown(task, :brutal_kill)

    assert_receive {:outbound_mcp,
                    %{
                      "method" => "notifications/cancelled",
                      "params" => %{
                        "requestId" => ^request_id,
                        "reason" => "Request caller exited"
                      }
                    }}

    wait_until(fn -> Client.get_pending_requests(client) == [] end)
    assert :sys.get_state(client).pending_caller_monitors == %{}

    next = Task.async(fn -> Client.call_tool(client, "fast", %{}, timeout: 1_000) end)
    assert_receive {:outbound_mcp, %{"method" => "tools/call", "id" => next_id}}

    send(
      client,
      {:transport_message,
       Jason.encode!(%{
         "jsonrpc" => "2.0",
         "id" => next_id,
         "result" => %{"content" => [%{"type" => "text", "text" => "ok"}]}
       })}
    )

    assert {:ok, %ExMCP.Response{}} = Task.await(next)
    assert :sys.get_state(client).pending_caller_monitors == %{}
  end

  test "caller ownership correlates cancellation when requests overlap", %{client: client} do
    first = Task.async(fn -> Client.call_tool(client, "first", %{}, timeout: 30_000) end)
    assert_receive {:outbound_mcp, %{"method" => "tools/call", "id" => first_id}}

    second = Task.async(fn -> Client.call_tool(client, "second", %{}, timeout: 30_000) end)
    assert_receive {:outbound_mcp, %{"method" => "tools/call", "id" => second_id}}
    assert first_id != second_id

    Task.shutdown(first, :brutal_kill)

    assert_receive {:outbound_mcp,
                    %{
                      "method" => "notifications/cancelled",
                      "params" => %{"requestId" => ^first_id}
                    }}

    assert Client.get_pending_requests(client) == [second_id]

    send(
      client,
      {:transport_message,
       Jason.encode!(%{
         "jsonrpc" => "2.0",
         "id" => second_id,
         "result" => %{"content" => [%{"type" => "text", "text" => "second"}]}
       })}
    )

    assert {:ok, %ExMCP.Response{}} = Task.await(second)
    assert Client.get_pending_requests(client) == []
    assert :sys.get_state(client).pending_caller_monitors == %{}
  end

  test "a caller-side timeout is eventually propagated even while the caller remains alive", %{
    client: client
  } do
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:call_result, Client.call_tool(client, "slow", %{}, timeout: 20)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:outbound_mcp, %{"method" => "tools/call", "id" => request_id}}

    assert_receive {:call_result,
                    {:error, %ExMCP.Error.ProtocolError{message: "Request timeout"}}},
                   500

    assert Process.alive?(caller)

    assert_receive {:outbound_mcp,
                    %{
                      "method" => "notifications/cancelled",
                      "params" => %{
                        "requestId" => ^request_id,
                        "reason" => "Request timed out"
                      }
                    }},
                   1_500

    wait_until(fn -> Client.get_pending_requests(client) == [] end)
    assert :sys.get_state(client).pending_caller_monitors == %{}
    send(caller, :stop)
  end

  @tag :tmp_dir
  test "caller death propagates through the real stdio transport", %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "stdio-cancellation.marker")
    script = Path.join(tmp_dir, "cooperative_mcp.py")
    File.write!(script, cooperative_stdio_server(marker))

    python = System.find_executable("python3") || raise "python3 is required"

    {:ok, client} =
      Client.start_link(
        transport: :stdio,
        command: [python, script],
        protocol_mode: :legacy_only,
        environment_policy: :isolated,
        reconnect: false,
        health_check_interval: nil
      )

    task = Task.async(fn -> Client.call_tool(client, "slow", %{}, timeout: 30_000) end)
    wait_until(fn -> File.exists?(marker) end)
    assert File.read!(marker) == "started\n"

    Task.shutdown(task, :brutal_kill)

    wait_until(fn ->
      case File.read(marker) do
        {:ok, contents} -> String.contains?(contents, "stopped")
        _missing -> false
      end
    end)

    assert File.read!(marker) == "started\ncancel-notification\nstopped\n"
    assert Client.get_pending_requests(client) == []
    assert :sys.get_state(client).pending_caller_monitors == %{}
    :ok = Client.disconnect(client)
  end

  defp cooperative_stdio_server(marker) do
    """
    import json
    import sys
    import threading

    marker = #{inspect(marker)}
    cancelled = {}
    output_lock = threading.Lock()

    def mark(text):
        with output_lock:
            with open(marker, "a", encoding="utf-8") as handle:
                handle.write(text + "\\n")
                handle.flush()

    def respond(payload):
        with output_lock:
            sys.stdout.write(json.dumps(payload) + "\\n")
            sys.stdout.flush()

    def run_slow(request_id):
        mark("started")
        if cancelled[request_id].wait(5.0):
            mark("stopped")
        else:
            mark("late")
            respond({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": "late"}]}})

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")

        if method == "notifications/cancelled":
            mark("cancel-notification")
            event = cancelled.get(message.get("params", {}).get("requestId"))
            if event is not None:
                event.set()
            continue

        if request_id is None:
            continue

        if method == "initialize":
            result = {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "caller-owned-stdio", "version": "1"},
            }
        elif method == "tools/list":
            result = {"tools": [{"name": "slow", "description": "block", "inputSchema": {"type": "object"}}]}
        elif method == "tools/call":
            cancelled[request_id] = threading.Event()
            threading.Thread(target=run_slow, args=(request_id,), daemon=True).start()
            continue
        else:
            continue

        respond({"jsonrpc": "2.0", "id": request_id, "result": result})
    """
  end
end
