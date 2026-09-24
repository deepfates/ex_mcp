defmodule ExMCP.ACP.Client.HandlerRunnerCompatTest do
  use ExUnit.Case, async: true

  alias ExMCP.ACP.Client.HandlerRunner

  defmodule CaptureHandler do
    @behaviour ExMCP.ACP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{pid: Keyword.fetch!(opts, :pid)}}

    @impl true
    def handle_session_update(session_id, update, state) do
      send(state.pid, {:session_update, session_id, update})
      {:ok, state}
    end

    @impl true
    def handle_permission_request(_session_id, _tool_call, _options, state),
      do: {:ok, %{"outcome" => "cancelled"}, state}

    @impl true
    def handle_file_read(_session_id, _path, _opts, state), do: {:error, :not_supported, state}

    @impl true
    def handle_file_write(_session_id, _path, _content, state),
      do: {:error, :not_supported, state}

    @impl true
    def handle_terminal_request(_method, _params, _id, state), do: {:error, :not_supported, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule AsyncTerminalHandler do
    @behaviour ExMCP.ACP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent), dispatches: 0}}

    @impl true
    def handle_session_update(_session_id, _update, state), do: {:ok, state}

    @impl true
    def handle_permission_request(_session_id, _tool_call, _options, state),
      do: {:ok, %{"outcome" => "cancelled"}, state}

    @impl true
    def handle_terminal_request("terminal/wait_for_exit", _params, _id, state) do
      parent = state.parent

      work = fn ->
        send(parent, {:async_terminal_started, self()})

        receive do
          :release_async_terminal -> {:ok, %{"exitCode" => 0}}
        end
      end

      {:async, work, %{state | dispatches: state.dispatches + 1}}
    end

    def handle_terminal_request("terminal/kill", _params, _id, state) do
      send(state.parent, {:terminal_kill_dispatched, self(), state.dispatches})
      {:ok, %{}, state}
    end
  end

  test "session_update/3 remains as an rc.6 compatibility wrapper" do
    {:ok, pid} = HandlerRunner.start_link(CaptureHandler, [pid: self()], self())

    assert :ok =
             HandlerRunner.session_update(pid, "s1", %{"sessionUpdate" => "agent_message_chunk"})

    assert_receive {:session_update, "s1", %{"sessionUpdate" => "agent_message_chunk"}}
  end

  test "session_update/3 returns :ok when the runner is already dead" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = HandlerRunner.start_link(CaptureHandler, [pid: self()], self())
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert :dropped =
             HandlerRunner.session_update(pid, "s1", %{"sessionUpdate" => "dead"}, 32, 8_388_608)

    assert :ok = HandlerRunner.session_update(pid, "s1", %{"sessionUpdate" => "dead"})
  end

  test "session_update/3 returns :ok when bounded /5 delivery would drop" do
    {:ok, pid} = HandlerRunner.start_link(CaptureHandler, [pid: self()], self())

    update = %{
      "sessionUpdate" => "agent_message_chunk",
      "pad" => String.duplicate("x", 10_000)
    }

    assert :dropped = HandlerRunner.session_update(pid, "s1", update, 32, 64)
    assert :ok = HandlerRunner.session_update(pid, "s1", update)
  end

  test "async terminal work does not block later callbacks and preserves serialized state" do
    {:ok, runner} = HandlerRunner.start_link(AsyncTerminalHandler, [parent: self()], self())
    wait_ref = make_ref()
    kill_ref = make_ref()

    HandlerRunner.terminal_request(
      runner,
      wait_ref,
      "terminal/wait_for_exit",
      %{"terminalId" => "term_1"},
      1
    )

    assert_receive {:async_terminal_started, worker}
    worker_monitor = Process.monitor(worker)

    HandlerRunner.terminal_request(
      runner,
      kill_ref,
      "terminal/kill",
      %{"terminalId" => "term_1"},
      2
    )

    assert_receive {:terminal_kill_dispatched, ^runner, 1}
    assert_receive {:acp_handler_result, ^kill_ref, {:terminal, {:ok, %{}}}}

    HandlerRunner.cancel_request(runner, wait_ref)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    refute_receive {:acp_handler_result, ^wait_ref, _result}, 50
  end

  test "async terminal work completes through the ordinary handler result path" do
    {:ok, runner} = HandlerRunner.start_link(AsyncTerminalHandler, [parent: self()], self())
    wait_ref = make_ref()

    HandlerRunner.terminal_request(
      runner,
      wait_ref,
      "terminal/wait_for_exit",
      %{"terminalId" => "term_1"},
      1
    )

    assert_receive {:async_terminal_started, worker}
    send(worker, :release_async_terminal)

    assert_receive {:acp_handler_result, ^wait_ref, {:terminal, {:ok, %{"exitCode" => 0}}}}
  end

  test "stopping the handler runner kills its owned async work" do
    {:ok, runner} = HandlerRunner.start_link(AsyncTerminalHandler, [parent: self()], self())
    wait_ref = make_ref()

    HandlerRunner.terminal_request(
      runner,
      wait_ref,
      "terminal/wait_for_exit",
      %{"terminalId" => "term_1"},
      1
    )

    assert_receive {:async_terminal_started, worker}
    worker_monitor = Process.monitor(worker)
    GenServer.stop(runner)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
  end
end
