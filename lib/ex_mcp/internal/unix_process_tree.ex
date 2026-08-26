defmodule ExMCP.Internal.UnixProcessTree do
  @moduledoc false

  @max_freeze_passes 16
  @confirmation_attempts 100
  @confirmation_interval_ms 10

  @spec freeze_and_kill_descendants(pos_integer()) ::
          {:ok, [pos_integer()]} | {:error, term()}
  def freeze_and_kill_descendants(root_pid) when is_integer(root_pid) and root_pid > 0 do
    with {:ok, commands} <- commands(),
         :ok <- signal(commands.kill, root_pid, "STOP"),
         {:ok, descendants} <- freeze_to_fixed_point(commands, root_pid),
         :ok <- signal_all(commands.kill, descendants, "KILL") do
      {:ok, descendants}
    end
  end

  @spec confirm_gone([pos_integer()]) :: :ok | {:error, {:processes_remain, [pos_integer()]}}
  def confirm_gone(pids) when is_list(pids) do
    confirm_gone(Map.new(pids, &{&1, true}), @confirmation_attempts)
  end

  defp freeze_to_fixed_point(commands, root_pid) do
    freeze_pass(commands, root_pid, %{}, @max_freeze_passes)
  end

  defp freeze_pass(_commands, _root_pid, _known, 0),
    do: {:error, :process_tree_did_not_stabilize}

  defp freeze_pass(commands, root_pid, known, passes_left) do
    with {:ok, process_table} <- process_table(commands.ps) do
      descendants = descendants(process_table, root_pid)
      newly_seen = Map.drop(descendants, Map.keys(known))

      case signal_all(commands.kill, newly_seen, "STOP") do
        :ok ->
          if map_size(newly_seen) == 0 do
            {:ok, descendants |> Map.keys() |> Enum.sort(:desc)}
          else
            freeze_pass(
              commands,
              root_pid,
              Map.merge(known, newly_seen),
              passes_left - 1
            )
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp descendants(process_table, root_pid) do
    children_by_parent =
      Enum.reduce(process_table, %{}, fn {pid, parent_pid}, acc ->
        Map.update(acc, parent_pid, [pid], &[pid | &1])
      end)

    collect_descendants(children_by_parent, [root_pid], %{})
  end

  defp collect_descendants(_children_by_parent, [], descendants), do: descendants

  defp collect_descendants(children_by_parent, [parent | rest], descendants) do
    unseen =
      children_by_parent
      |> Map.get(parent, [])
      |> Enum.reject(&Map.has_key?(descendants, &1))

    collect_descendants(
      children_by_parent,
      unseen ++ rest,
      Enum.reduce(unseen, descendants, &Map.put(&2, &1, true))
    )
  end

  defp process_table(ps) do
    case System.cmd(ps, ["-axo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        entries =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce([], fn line, acc ->
            case String.split(line) do
              [pid, parent_pid] ->
                case {Integer.parse(pid), Integer.parse(parent_pid)} do
                  {{pid, ""}, {parent_pid, ""}} -> [{pid, parent_pid} | acc]
                  _invalid -> acc
                end

              _invalid ->
                acc
            end
          end)

        {:ok, entries}

      {output, status} ->
        {:error, {:process_table_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:process_table_failed, error}}
  end

  defp signal_all(kill, pids, signal) do
    pids = if is_map(pids), do: Map.keys(pids), else: pids

    Enum.reduce_while(pids, :ok, fn pid, :ok ->
      case signal(kill, pid, signal) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp signal(kill, pid, signal) do
    case System.cmd(kill, ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        if alive?(kill, pid) do
          {:error, {:signal_failed, signal, pid, status, String.trim(output)}}
        else
          :ok
        end
    end
  rescue
    error -> {:error, {:signal_failed, signal, pid, error}}
  end

  defp confirm_gone(pids, attempts_left) do
    cond do
      map_size(pids) == 0 ->
        :ok

      attempts_left == 0 ->
        {:error, {:processes_remain, pids |> Map.keys() |> Enum.sort()}}

      true ->
        case commands() do
          {:ok, %{kill: kill}} ->
            remaining =
              pids |> Map.keys() |> Enum.filter(&alive?(kill, &1)) |> Map.new(&{&1, true})

            if map_size(remaining) == 0 do
              :ok
            else
              Process.sleep(@confirmation_interval_ms)
              confirm_gone(remaining, attempts_left - 1)
            end

          {:error, _reason} ->
            {:error, {:processes_remain, pids |> Map.keys() |> Enum.sort()}}
        end
    end
  end

  defp alive?(kill, pid) do
    match?({_output, 0}, System.cmd(kill, ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  rescue
    _error -> true
  end

  defp commands do
    with ps when is_binary(ps) <- System.find_executable("ps"),
         kill when is_binary(kill) <- System.find_executable("kill") do
      {:ok, %{ps: ps, kill: kill}}
    else
      nil -> {:error, :process_control_unavailable}
    end
  end
end
