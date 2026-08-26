defmodule ExMCP.Internal.OwnedProcessTest do
  use ExUnit.Case, async: false

  alias ExMCP.Internal.OwnedProcess

  @tag :unix
  test "owner death tears down the isolated process group" do
    parent = self()
    shell = System.find_executable("sh") || flunk("sh executable is required")

    controller =
      spawn(fn ->
        script = """
        trap '' TERM
        sleep 120 &
        child=$!
        printf '%s %s\\n' $$ "$child"
        wait
        """

        {:ok, process} =
          OwnedProcess.open(shell, ["-c", script],
            cd: File.cwd!(),
            env: []
          )

        line = receive_first_line(process)
        send(parent, {:owned_process, process, line})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:owned_process, _process, line}, 5_000
    [leader_pid, child_pid] = parse_pids(line)

    on_exit(fn ->
      force_kill(leader_pid)
      force_kill(child_pid)
    end)

    assert os_process_alive?(leader_pid)
    assert os_process_alive?(child_pid)

    Process.exit(controller, :kill)

    refute eventually(fn -> os_process_alive?(leader_pid) end)
    refute eventually(fn -> os_process_alive?(child_pid) end)
  end

  defp receive_first_line(process, buffer \\ "") do
    receive do
      {^process, {:data, data}} ->
        buffer = buffer <> data

        case String.split(buffer, "\n", parts: 2) do
          [line, _rest] -> line
          [_partial] -> receive_first_line(process, buffer)
        end
    after
      5_000 -> flunk("timed out waiting for process tree probe: #{inspect(buffer)}")
    end
  end

  defp parse_pids(line) do
    line
    |> String.split()
    |> Enum.map(&String.to_integer/1)
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, attempts) do
    if predicate.() do
      Process.sleep(20)
      eventually(predicate, attempts - 1)
    else
      false
    end
  end

  defp os_process_alive?(pid) do
    match?(
      {_output, 0},
      System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    )
  end

  defp force_kill(pid) do
    if os_process_alive?(pid) do
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
