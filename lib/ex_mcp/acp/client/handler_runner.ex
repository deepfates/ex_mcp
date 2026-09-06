defmodule ExMCP.ACP.Client.HandlerRunner do
  @moduledoc false

  use GenServer

  require Logger

  defstruct [:handler_mod, :handler_state, :owner, async_requests: %{}, async_monitors: %{}]

  def start_link(handler_mod, handler_opts, owner) do
    GenServer.start_link(__MODULE__, {handler_mod, handler_opts, owner})
  end

  # rc.6 compatibility: unbounded enqueue used Client defaults after security harden.
  @default_max_update_queue 32
  @default_max_update_queue_bytes 8_388_608

  @doc false
  def session_update(pid, session_id, update) do
    _ =
      session_update(
        pid,
        session_id,
        update,
        @default_max_update_queue,
        @default_max_update_queue_bytes
      )

    :ok
  end

  def session_update(pid, session_id, update, max_queue, max_queue_bytes) do
    incoming_bytes = :erlang.external_size(update)

    if update_mailbox_below_limits?(pid, max_queue, max_queue_bytes, incoming_bytes) do
      GenServer.cast(pid, {:session_update, session_id, update})
      :ok
    else
      :dropped
    end
  end

  defp update_mailbox_below_limits?(pid, count_limit, byte_limit, incoming_bytes) do
    with {:message_queue_len, length} when length < count_limit <-
           Process.info(pid, :message_queue_len),
         {:messages, messages} when length(messages) < count_limit <-
           Process.info(pid, :messages) do
      queued_bytes = queued_update_bytes(messages, byte_limit)
      incoming_bytes <= byte_limit - queued_bytes
    else
      _full_or_closed -> false
    end
  end

  defp queued_update_bytes(messages, limit) do
    Enum.reduce_while(messages, 0, fn message, total ->
      total = total + queued_update_size(message)
      if total >= limit, do: {:halt, total}, else: {:cont, total}
    end)
  end

  defp queued_update_size({:"$gen_cast", {:session_update, _session_id, update}}),
    do: :erlang.external_size(update)

  defp queued_update_size(_message), do: 0

  def permission_request(pid, ref, session_id, tool_call, options) do
    GenServer.cast(pid, {:permission_request, ref, session_id, tool_call, options})
  end

  def file_read(pid, ref, session_id, path, opts) do
    GenServer.cast(pid, {:file_read, ref, session_id, path, opts})
  end

  def file_write(pid, ref, session_id, path, content) do
    GenServer.cast(pid, {:file_write, ref, session_id, path, content})
  end

  def terminal_request(pid, ref, method, params, id) do
    GenServer.cast(pid, {:terminal_request, ref, method, params, id})
  end

  def cancel_request(pid, ref) when is_reference(ref) do
    GenServer.cast(pid, {:cancel_request, ref})
  end

  def elicitation_request(pid, ref, mode, params) do
    GenServer.cast(pid, {:elicitation_request, ref, mode, params})
  end

  def elicitation_complete(pid, elicitation_id) do
    GenServer.cast(pid, {:elicitation_complete, elicitation_id})
  end

  @impl true
  def init({handler_mod, handler_opts, owner}) do
    Process.flag(:trap_exit, true)

    case safe_call(fn -> handler_mod.init(handler_opts) end) do
      {:ok, {:ok, handler_state}} ->
        {:ok, %__MODULE__{handler_mod: handler_mod, handler_state: handler_state, owner: owner}}

      {:ok, {:error, reason}} ->
        {:stop, {:handler_init_failed, reason}}

      {:ok, other} ->
        {:stop, {:handler_init_failed, {:invalid_return, other}}}

      {:error, reason} ->
        {:stop, {:handler_init_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:session_update, session_id, update}, state) do
    case safe_call(fn ->
           state.handler_mod.handle_session_update(session_id, update, state.handler_state)
         end) do
      {:ok, {:ok, handler_state}} ->
        {:noreply, %{state | handler_state: handler_state}}

      {:ok, other} ->
        Logger.warning("ACP handler returned invalid session update result",
          return_shape: return_shape(other)
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("ACP handler session update failed", error_class: error_class(reason))
        {:noreply, state}
    end
  end

  def handle_cast({:permission_request, ref, session_id, tool_call, options}, state) do
    dispatch_request(
      state,
      ref,
      :permission,
      :value,
      fn ->
        state.handler_mod.handle_permission_request(
          session_id,
          tool_call,
          options,
          state.handler_state
        )
      end
    )
  end

  def handle_cast({:file_read, ref, session_id, path, opts}, state) do
    dispatch_request(state, ref, :file_read, :value, fn ->
      state.handler_mod.handle_file_read(session_id, path, opts, state.handler_state)
    end)
  end

  def handle_cast({:file_write, ref, session_id, path, content}, state) do
    dispatch_request(state, ref, :file_write, :unit, fn ->
      state.handler_mod.handle_file_write(session_id, path, content, state.handler_state)
    end)
  end

  def handle_cast({:terminal_request, ref, method, params, id}, state) do
    dispatch_request(state, ref, :terminal, :value, fn ->
      state.handler_mod.handle_terminal_request(method, params, id, state.handler_state)
    end)
  end

  def handle_cast({:elicitation_request, ref, mode, params}, state) do
    callback = if mode == "form", do: :handle_form_elicitation, else: :handle_url_elicitation

    dispatch_request(state, ref, :elicitation, :value, fn ->
      apply(state.handler_mod, callback, [params, state.handler_state])
    end)
  end

  def handle_cast({:cancel_request, ref}, state) do
    {:noreply, cancel_async_request(state, ref)}
  end

  def handle_cast({:elicitation_complete, elicitation_id}, state) do
    state =
      case safe_call(fn ->
             state.handler_mod.handle_elicitation_complete(elicitation_id, state.handler_state)
           end) do
        {:ok, {:ok, handler_state}} -> %{state | handler_state: handler_state}
        _invalid_or_failed -> state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:async_request_result, ref, pid, result}, state) do
    case pop_async_request(state, ref, pid) do
      {:ok, kind, state} ->
        send(state.owner, {:acp_handler_result, ref, {kind, result}})
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, pid, reason},
        %{async_monitors: monitors} = state
      )
      when is_map_key(monitors, monitor_ref) do
    ref = Map.fetch!(monitors, monitor_ref)

    case pop_async_request(state, ref, pid) do
      {:ok, kind, state} ->
        send(
          state.owner,
          {:acp_handler_result, ref, {kind, {:error, {:async_request_exit, reason}}}}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state) do
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Enum.each(state.async_requests, fn {_ref, request} ->
      Process.exit(request.pid, :kill)
      Process.demonitor(request.monitor_ref, [:flush])
    end)

    if function_exported?(state.handler_mod, :terminate, 2) do
      _ = safe_call(fn -> state.handler_mod.terminate(reason, state.handler_state) end)
    end

    :ok
  end

  defp dispatch_request(state, ref, kind, result_mode, callback) do
    case safe_call(callback) do
      {:ok, {:async, work, handler_state}} when is_function(work, 0) ->
        state = %{state | handler_state: handler_state}
        {:noreply, start_async_request(state, ref, kind, result_mode, work)}

      callback_result ->
        {result, state} = normalize_sync_result(callback_result, result_mode, state)
        send(state.owner, {:acp_handler_result, ref, {kind, result}})
        {:noreply, state}
    end
  end

  defp normalize_sync_result({:ok, {:ok, response, handler_state}}, :value, state),
    do: {{:ok, response}, %{state | handler_state: handler_state}}

  defp normalize_sync_result({:ok, {:ok, handler_state}}, :unit, state),
    do: {:ok, %{state | handler_state: handler_state}}

  defp normalize_sync_result({:ok, {:error, reason, handler_state}}, _mode, state),
    do: {{:error, reason}, %{state | handler_state: handler_state}}

  defp normalize_sync_result({:ok, other}, _mode, state),
    do: {{:error, {:invalid_return, other}}, state}

  defp normalize_sync_result({:error, reason}, _mode, state), do: {{:error, reason}, state}

  defp start_async_request(state, ref, kind, result_mode, work) do
    parent = self()

    {pid, monitor_ref} =
      :erlang.spawn_opt(
        fn ->
          result = work |> safe_call() |> normalize_async_result(result_mode)
          send(parent, {:async_request_result, ref, self(), result})
        end,
        [:link, :monitor]
      )

    request = %{pid: pid, monitor_ref: monitor_ref, kind: kind}

    %{
      state
      | async_requests: Map.put(state.async_requests, ref, request),
        async_monitors: Map.put(state.async_monitors, monitor_ref, ref)
    }
  end

  defp normalize_async_result({:ok, {:ok, response}}, :value), do: {:ok, response}
  defp normalize_async_result({:ok, :ok}, :unit), do: :ok
  defp normalize_async_result({:ok, {:error, reason}}, _mode), do: {:error, reason}
  defp normalize_async_result({:ok, other}, _mode), do: {:error, {:invalid_return, other}}
  defp normalize_async_result({:error, reason}, _mode), do: {:error, reason}

  defp cancel_async_request(state, ref) do
    case Map.pop(state.async_requests, ref) do
      {nil, _requests} ->
        state

      {request, requests} ->
        Process.exit(request.pid, :kill)
        Process.demonitor(request.monitor_ref, [:flush])

        %{
          state
          | async_requests: requests,
            async_monitors: Map.delete(state.async_monitors, request.monitor_ref)
        }
    end
  end

  defp pop_async_request(state, ref, pid) do
    case Map.get(state.async_requests, ref) do
      %{pid: ^pid, monitor_ref: monitor_ref, kind: kind} ->
        Process.demonitor(monitor_ref, [:flush])

        {:ok, kind,
         %{
           state
           | async_requests: Map.delete(state.async_requests, ref),
             async_monitors: Map.delete(state.async_monitors, monitor_ref)
         }}

      _missing_or_replaced ->
        :error
    end
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      {:error, {kind, reason, __STACKTRACE__}}
  end

  defp return_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp return_shape(value) when is_map(value), do: :map
  defp return_shape(value) when is_list(value), do: :list
  defp return_shape(value) when is_atom(value), do: :atom
  defp return_shape(_value), do: :other

  defp error_class({kind, reason, _stack}) when kind in [:error, :exit, :throw],
    do: {kind, exception_module(reason)}

  defp exception_module(%{__struct__: module}) when is_atom(module), do: module
  defp exception_module(_reason), do: :non_exception
end
