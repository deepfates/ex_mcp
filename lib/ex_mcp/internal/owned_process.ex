defmodule ExMCP.Internal.OwnedProcess do
  @moduledoc false

  use GenServer

  alias ExMCP.Internal.UnixProcessTree

  @shutdown_timeout_ms 2_500
  @kill_timeout_seconds 1

  defstruct [:pid, :os_pid]

  @type t :: %__MODULE__{pid: pid(), os_pid: pos_integer()}

  @spec open(String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def open(executable, args, opts \\ []) do
    GenServer.start_link(__MODULE__, {self(), executable, args, opts})
    |> case do
      {:ok, pid} -> {:ok, GenServer.call(pid, :handle)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec command(t(), iodata()) :: :ok | {:error, term()}
  def command(%__MODULE__{pid: pid}, data), do: GenServer.call(pid, {:send, data})
  def command(_closed_or_invalid_process, _data), do: {:error, :closed}

  @spec transfer(t(), pid()) :: :ok | {:error, :closed}
  def transfer(%__MODULE__{pid: pid}, owner) when is_pid(owner) do
    GenServer.call(pid, {:transfer, owner})
  catch
    :exit, _reason -> {:error, :closed}
  end

  @spec close(t() | nil) :: :ok | {:error, term()}
  def close(nil), do: :ok

  def close(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :close, @shutdown_timeout_ms + 500)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, reason -> {:error, {:process_close_failed, reason}}
  end

  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :alive?)
  catch
    :exit, _reason -> false
  end

  @impl true
  def init({owner, executable, args, opts}) do
    Process.flag(:trap_exit, true)

    exec_opts = [
      :stdin,
      {:stdout, self()},
      {:stderr, self()},
      {:group, 0},
      :kill_group,
      {:kill_timeout, @kill_timeout_seconds},
      {:cd, Keyword.fetch!(opts, :cd)},
      {:env, normalize_env(Keyword.get(opts, :env, []), opts)}
    ]

    case :exec.run_link([executable | args], exec_opts) do
      {:ok, exec_pid, os_pid} ->
        monitor_ref = Process.monitor(exec_pid)

        {:ok,
         %{
           owner: owner,
           controller: owner,
           exec_pid: exec_pid,
           monitor_ref: monitor_ref,
           handle: %__MODULE__{pid: self(), os_pid: os_pid},
           closing?: false
         }}

      {:error, reason} ->
        {:stop, {:process_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:handle, _from, state), do: {:reply, state.handle, state}
  def handle_call(:alive?, _from, state), do: {:reply, is_pid(state.exec_pid), state}

  def handle_call({:send, _data}, _from, %{exec_pid: nil} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send, data}, _from, state) do
    {:reply, :exec.send(state.exec_pid, IO.iodata_to_binary(data)), state}
  end

  def handle_call({:transfer, owner}, _from, state) do
    {:reply, :ok, %{state | owner: owner}}
  end

  def handle_call(:close, _from, %{exec_pid: nil} = state) do
    {:stop, :normal, :ok, %{state | closing?: true}}
  end

  def handle_call(:close, _from, state) do
    descendants = freeze_and_kill_descendants(state.handle.os_pid)
    :ok = stop_exec(state.exec_pid)
    await_down(state.monitor_ref, state.exec_pid, state.owner, state.handle)
    :ok = UnixProcessTree.confirm_gone(descendants)
    {:stop, :normal, :ok, %{state | closing?: true}}
  end

  @impl true
  def handle_info({stream, os_pid, data}, %{handle: %{os_pid: os_pid}} = state)
      when stream in [:stdout, :stderr] do
    send(state.owner, {state.handle, {:data, data}})
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, exec_pid, reason},
        %{monitor_ref: monitor_ref, exec_pid: exec_pid} = state
      ) do
    unless state.closing? do
      send(state.owner, {state.handle, {:exit_status, exit_status(reason)}})
      send(state.owner, {state.handle, :eof})
    end

    {:noreply, %{state | monitor_ref: nil, exec_pid: nil}}
  end

  def handle_info({:EXIT, exec_pid, _reason}, %{exec_pid: exec_pid} = state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, controller, reason}, %{controller: controller} = state) do
    {:stop, {:owner_down, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{exec_pid: exec_pid, handle: %{os_pid: os_pid}})
      when is_pid(exec_pid) do
    _descendants = freeze_and_kill_descendants(os_pid)
    stop_exec(exec_pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp stop_exec(exec_pid) do
    case :exec.stop(exec_pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> :ok
  end

  defp freeze_and_kill_descendants(os_pid) do
    case :os.type() do
      {:unix, _name} ->
        case UnixProcessTree.freeze_and_kill_descendants(os_pid) do
          {:ok, descendants} -> descendants
          {:error, reason} -> exit({:process_tree_shutdown_failed, reason})
        end

      {:win32, _name} ->
        []
    end
  end

  defp await_down(monitor_ref, exec_pid, owner, handle) do
    receive do
      {stream, os_pid, data} when stream in [:stdout, :stderr] and os_pid == handle.os_pid ->
        send(owner, {handle, {:data, data}})
        await_down(monitor_ref, exec_pid, owner, handle)

      {:DOWN, ^monitor_ref, :process, ^exec_pid, _reason} ->
        :ok

      {:EXIT, ^exec_pid, _reason} ->
        await_down(monitor_ref, exec_pid, owner, handle)
    after
      @shutdown_timeout_ms ->
        :ok
    end
  end

  defp exit_status(:normal), do: 0

  defp exit_status({:exit_status, status}) when is_integer(status) do
    case :exec.status(status) do
      {:status, code} -> code
      {:signal, signal, _core?} when is_integer(signal) -> 128 + signal
      {:signal, _signal, _core?} -> 1
    end
  end

  defp exit_status({:signal, signal, _core?}) when is_integer(signal), do: 128 + signal
  defp exit_status(_reason), do: 1

  # Erlang represents an empty charlist as [], which erlexec correctly reads as
  # a list rather than an empty string. Use binaries at this boundary so empty
  # environment values remain unambiguous.
  defp normalize_env(env, opts) do
    inherited =
      if Keyword.get(opts, :inherit_environment, false),
        do: System.get_env(),
        else: %{}

    explicit =
      Map.new(env, fn
        {name, false} -> {to_string(name), false}
        {name, value} -> {to_string(name), to_string(value)}
      end)

    values =
      inherited
      |> Map.merge(explicit)
      |> Enum.map(fn {name, value} -> {name, value} end)

    # The erlexec manager is long-lived, so its own launch environment may be
    # stale. Clear it and send the exact environment selected for this child.
    [:clear | values]
  end
end
