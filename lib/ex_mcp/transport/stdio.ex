defmodule ExMCP.Transport.Stdio do
  @moduledoc """
  This module implements the standard MCP specification.

  stdio transport implementation for MCP.

  This transport communicates with MCP servers over standard input/output,
  typically by spawning a subprocess. This is one of the two official MCP
  transports defined in the specification.

  ## Options

  - `:command` - Command and arguments to spawn (required)
  - `:cd` - Working directory for the process
  - `:env` - Environment variables as a list of `{"KEY", "VALUE"}` tuples;
    use `{"KEY", false}` to remove an inherited variable from the child
  - `:environment_policy` - `:isolated` (default) passes only a small runtime
    allowlist plus explicit `:env`; `:inherit` preserves the parent environment
    for explicitly trusted deployments
  - `:max_frame_bytes` - maximum inbound or outbound JSON-RPC frame size
    (default: 1 MiB)

  ## Example

      {:ok, client} = ExMCP.Client.start_link(
        transport: :stdio,
        command: ["node", "my-mcp-server.js"],
        cd: "/path/to/server",
        env: [{"NODE_ENV", "production"}]
      )
  """

  @behaviour ExMCP.Transport

  require Logger

  alias ExMCP.Internal.{
    LineBuffer,
    LogSummary,
    Options,
    OwnedProcess,
    PortEnvironment,
    SecurityConfig
  }

  alias ExMCP.Transport.{Error, SecurityGuard}

  @default_max_frame_bytes 1_048_576
  defstruct [
    :port,
    :os_pid,
    :line_buffer,
    :subscriber,
    :reader_pid,
    max_frame_bytes: @default_max_frame_bytes
  ]

  @impl true
  def connect(opts) do
    with :ok <- PortEnvironment.validate_policy(opts) do
      do_connect(opts)
    end
  end

  defp do_connect(opts) do
    command = Keyword.fetch!(opts, :command)

    executable = hd(command)

    # Try to find the executable in common locations if it's not a full path
    executable_path =
      if Path.type(executable) == :absolute do
        executable
      else
        case System.find_executable(executable) do
          nil ->
            # Try common locations for node/npm/npx on macOS
            common_paths = [
              "/opt/homebrew/bin/#{executable}",
              "/usr/local/bin/#{executable}",
              "/usr/bin/#{executable}",
              "#{System.get_env("HOME")}/.nvm/versions/node/#{System.get_env("NODE_VERSION", "*")}/bin/#{executable}"
            ]

            Enum.find(common_paths, executable, &File.exists?/1)

          path ->
            path
        end
      end

    process_opts = [
      cd: Keyword.get(opts, :cd, File.cwd!()),
      env: safe_env(opts),
      inherit_environment: Keyword.get(opts, :environment_policy, :isolated) == :inherit
    ]

    case OwnedProcess.open(executable_path, tl(command), process_opts) do
      {:ok, process} ->
        state = %__MODULE__{
          port: process,
          os_pid: process.os_pid,
          line_buffer: "",
          max_frame_bytes:
            Options.positive_integer(opts, :max_frame_bytes, @default_max_frame_bytes)
        }

        :telemetry.execute([:ex_mcp, :transport, :connection, :opened], %{}, %{
          transport: :stdio,
          command_basename: Path.basename(executable_path),
          command_hash: LogSummary.fingerprint(executable_path)
        })

        {:ok, state}

      {:error, reason} ->
        Error.connection_error({:spawn_failed, reason})
    end
  end

  @impl true
  def send_message(message, %__MODULE__{port: port} = state) do
    # Check if message contains external resource requests that need security validation
    case request_within_limit(message, state.max_frame_bytes) do
      {:error, :frame_too_large} = error ->
        error

      :ok ->
        do_send_message(message, port, state)
    end
  end

  defp do_send_message(message, port, state) do
    case validate_stdio_message(message, state) do
      {:ok, validated_message} ->
        # MCP uses newline-delimited JSON
        data = validated_message <> "\n"

        :telemetry.execute([:ex_mcp, :transport, :message, :sent], %{size: byte_size(message)}, %{
          transport: :stdio
        })

        case OwnedProcess.command(port, data) do
          :ok -> {:ok, state}
          {:error, reason} -> Error.transport_error({:send_failed, reason})
        end

      {:error, security_error} ->
        Logger.warning("Stdio message blocked by security policy",
          error: security_error
        )

        Error.security_violation(security_error)
    end
  end

  defp validate_stdio_message(message, state) do
    # Step 1: Validate that message does not contain embedded newlines
    # MCP specification: "Messages are delimited by newlines, and MUST NOT contain embedded newlines"
    case validate_no_embedded_newlines(message) do
      :ok ->
        # Step 2: Validate that message is valid JSON
        case validate_json_format(message) do
          {:ok, parsed_message} ->
            # Step 3: Validate JSON-RPC 2.0 structure
            case validate_jsonrpc_structure(parsed_message) do
              :ok ->
                # Step 4: Check for external resource requests that need security validation
                validate_security_requirements(parsed_message, message, state)

              {:error, validation_error} ->
                Error.validation_error({:invalid_jsonrpc, validation_error})
            end

          {:error, json_error} ->
            Error.validation_error({:invalid_json, json_error})
        end

      {:error, newline_error} ->
        Error.validation_error({:embedded_newline, newline_error})
    end
  end

  defp validate_no_embedded_newlines(message) do
    if String.contains?(message, "\n") do
      {:error,
       "Message contains embedded newlines which violate MCP stdio transport requirements"}
    else
      :ok
    end
  end

  defp validate_json_format(message) do
    case Jason.decode(message) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, error} ->
        {:error, "Invalid JSON format: #{inspect(error)}"}
    end
  end

  defp validate_jsonrpc_structure(parsed_message) when is_map(parsed_message) do
    # Validate JSON-RPC 2.0 structure according to specification
    cond do
      not Map.has_key?(parsed_message, "jsonrpc") ->
        {:error, "Missing required 'jsonrpc' field"}

      parsed_message["jsonrpc"] != "2.0" ->
        {:error, "Invalid jsonrpc version, must be '2.0'"}

      # For requests, must have method and optionally id
      Map.has_key?(parsed_message, "method") ->
        validate_jsonrpc_request(parsed_message)

      # For responses, must have id and either result or error
      Map.has_key?(parsed_message, "id") ->
        validate_jsonrpc_response(parsed_message)

      true ->
        {:error, "Invalid JSON-RPC structure: must be request, response, or notification"}
    end
  end

  defp validate_jsonrpc_structure(parsed_message) when is_list(parsed_message) do
    # JSON-RPC batch request - validate each item
    if parsed_message == [] do
      {:error, "Empty batch requests are not allowed"}
    else
      Enum.reduce_while(parsed_message, :ok, fn item, _acc ->
        case validate_jsonrpc_structure(item) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, "Batch item invalid: #{error}"}}
        end
      end)
    end
  end

  defp validate_jsonrpc_structure(_parsed_message) do
    {:error, "JSON-RPC message must be an object or array"}
  end

  defp validate_jsonrpc_request(request) do
    cond do
      not is_binary(request["method"]) ->
        {:error, "Method must be a string"}

      String.starts_with?(request["method"], "rpc.") ->
        {:error, "Methods starting with 'rpc.' are reserved"}

      Map.has_key?(request, "id") and is_nil(request["id"]) ->
        {:error, "Request id cannot be null"}

      true ->
        :ok
    end
  end

  defp validate_jsonrpc_response(response) do
    has_result = Map.has_key?(response, "result")
    has_error = Map.has_key?(response, "error")

    cond do
      has_result and has_error ->
        {:error, "Response cannot have both result and error"}

      not has_result and not has_error ->
        {:error, "Response must have either result or error"}

      true ->
        :ok
    end
  end

  defp validate_security_requirements(parsed_message, original_message, state) do
    # Check for external resource requests that need security validation
    case parsed_message do
      %{"method" => "resources/read", "params" => %{"uri" => uri}} ->
        validate_resource_access(uri, original_message, state)

      %{"method" => "resources/list", "params" => %{"uri" => uri}} when is_binary(uri) ->
        validate_resource_access(uri, original_message, state)

      _ ->
        # Non-resource request, allow through
        {:ok, original_message}
    end
  end

  defp validate_resource_access(uri, message, state) do
    # Only validate if URI appears to be external (has scheme and host)
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) ->
        # This is an external resource, validate with SecurityGuard
        security_request = %{
          url: uri,
          headers: [],
          method: "GET",
          transport: :stdio,
          user_id: extract_stdio_user_id(state)
        }

        config = SecurityConfig.get_transport_config(:stdio)

        case SecurityGuard.validate_request(security_request, config) do
          {:ok, _sanitized_request} ->
            {:ok, message}

          {:error, security_error} ->
            {:error, security_error}
        end

      _ ->
        # Local/relative URI, allow through
        {:ok, message}
    end
  end

  defp extract_stdio_user_id(_state) do
    # Use system user as default for stdio transport
    System.get_env("USER") || System.get_env("USERNAME") || "stdio_user"
  end

  @impl true
  def receive_message(%__MODULE__{} = state) do
    receive_message(state, :infinity)
  end

  @doc """
  Receives a single message, waiting at most `timeout` milliseconds.

  Callers must run this in the process that owns the port (or in one that may
  take ownership): port ownership is transferred to the caller, and an OTP port
  is closed when its owner exits. Running it in a short-lived helper process
  would therefore kill the spawned program — which is why the handshake path
  uses this timeout-aware clause in-process instead of wrapping
  `receive_message/1` in a task.
  """
  @spec receive_message(%__MODULE__{}, timeout()) ::
          {:ok, binary(), %__MODULE__{}} | {:error, any()}
  def receive_message(%__MODULE__{port: port} = state, timeout) do
    case OwnedProcess.transfer(port, self()) do
      :ok -> receive_loop(state, timeout)
      {:error, :closed} -> Error.connection_error(:closed)
    end
  end

  @impl true
  def close(%__MODULE__{port: port, reader_pid: reader_pid}) do
    :telemetry.execute([:ex_mcp, :transport, :connection, :closed], %{}, %{transport: :stdio})

    # The owned-process boundary confirms the isolated OS process group has
    # stopped before close returns. Output may still be delivered to a push
    # reader while shutdown drains, so stop the reader only afterwards.
    OwnedProcess.close(port)

    if is_pid(reader_pid) and Process.alive?(reader_pid) do
      # The reader is a plain spawn_link receive loop that does not trap
      # exits, so an exit signal with reason :normal would be silently
      # ignored and leak the process. Unlink first so the kill cannot
      # cascade to the caller, then terminate it unconditionally.
      Process.unlink(reader_pid)
      Process.exit(reader_pid, :kill)
    end

    :ok
  end

  @impl true
  def connected?(%__MODULE__{port: port}) do
    OwnedProcess.alive?(port)
  end

  @doc """
  Subscribe to receive transport events (push model).

  Spawns an internal reader process that takes over port ownership,
  reads and parses JSON messages, and pushes them to the subscriber.
  """
  @impl true
  def subscribe(pid, %__MODULE__{port: port} = state) when is_pid(pid) do
    # Spawn the reader first, then transfer port ownership from the caller
    # (the current port owner). Transferring from the caller instead of from
    # inside the reader avoids a race where the port dies before the reader
    # is scheduled, which would crash the subscriber through the link.
    reader =
      spawn_link(fn ->
        receive do
          :port_transferred -> stdio_reader_loop(port, "", pid, state.max_frame_bytes)
        end
      end)

    case OwnedProcess.transfer(port, reader) do
      :ok ->
        send(reader, :port_transferred)
        {:ok, %{state | subscriber: pid, reader_pid: reader}}

      {:error, :closed} ->
        Process.unlink(reader)
        Process.exit(reader, :kill)
        {:error, :port_closed}
    end
  end

  @impl true
  def capabilities(%__MODULE__{}), do: [:push]

  # Testing support - expose process_data for unit tests
  @doc false
  def process_data(data, state), do: do_process_data(data, state)

  # Private functions

  # `timeout` bounds the wait for a *complete* line: each partial chunk resets
  # the remaining budget only by the time already spent, so a slow-drip server
  # cannot extend the deadline indefinitely.
  defp receive_loop(state, timeout) do
    started = System.monotonic_time(:millisecond)

    receive do
      {port, {:data, data}} when port == state.port ->
        do_process_data(data, state, remaining(timeout, started))

      {port, {:exit_status, status}} when port == state.port ->
        Error.connection_error({:process_exited, status})

      {port, :eof} when port == state.port ->
        Error.connection_error(:eof)
    after
      timeout -> {:error, :handshake_timeout}
    end
  end

  defp remaining(:infinity, _started), do: :infinity

  defp remaining(timeout, started) do
    max(timeout - (System.monotonic_time(:millisecond) - started), 0)
  end

  defp do_process_data(data, state, timeout \\ :infinity) do
    # Handle both binary and :eol tuple format from port
    binary_data =
      case data do
        {:eol, line} -> line <> "\n"
        {:noeol, line} -> line
        binary when is_binary(binary) -> binary
        _ -> ""
      end

    # Accumulate data until we have a complete line, but never retain an
    # attacker-controlled delimiter-free frame beyond the configured bound.
    with {:ok, new_buffer} <- append_frame(state.line_buffer, binary_data, state.max_frame_bytes) do
      process_received_buffer(new_buffer, state, timeout)
    end
  end

  defp process_received_buffer(new_buffer, state, timeout) do
    case String.split(new_buffer, "\n", parts: 2) do
      [line, rest] ->
        # We have a complete line
        trimmed = String.trim(line)

        cond do
          trimmed == "" ->
            # Empty line, continue
            receive_loop(%{state | line_buffer: rest}, timeout)

          # Skip non-JSON output like "Secure MCP Filesystem Server..."
          not String.starts_with?(trimmed, "{") and not String.starts_with?(trimmed, "[") ->
            Logger.debug("Skipping non-JSON output", line_shape: LogSummary.describe(trimmed))
            receive_loop(%{state | line_buffer: rest}, timeout)

          true ->
            # Return the JSON line and update state
            :telemetry.execute(
              [:ex_mcp, :transport, :message, :received],
              %{size: byte_size(trimmed)},
              %{transport: :stdio}
            )

            {:ok, trimmed, %{state | line_buffer: rest}}
        end

      [partial] ->
        # No complete line yet, keep buffering
        receive_loop(%{state | line_buffer: partial}, timeout)
    end
  end

  # Internal reader process for push mode.
  # Reads port data, buffers lines, parses JSON, pushes to subscriber.
  defp stdio_reader_loop(port, line_buffer, subscriber, max_frame_bytes) do
    receive do
      {^port, {:data, data}} ->
        binary_data =
          case data do
            {:eol, line} -> line <> "\n"
            {:noeol, line} -> line
            binary when is_binary(binary) -> binary
            _ -> ""
          end

        case append_frame(line_buffer, binary_data, max_frame_bytes) do
          {:ok, new_buffer} ->
            remaining = process_buffer(new_buffer, subscriber, max_frame_bytes)
            stdio_reader_loop(port, remaining, subscriber, max_frame_bytes)

          {:error, :frame_too_large} ->
            Kernel.send(subscriber, {:transport_closed, :frame_too_large})
            OwnedProcess.close(port)
        end

      {^port, {:exit_status, status}} ->
        Kernel.send(subscriber, {:transport_closed, {:process_exited, status}})

      {^port, :eof} ->
        Kernel.send(subscriber, {:transport_closed, :eof})
    end
  end

  # Process buffered data, sending complete JSON messages to subscriber.
  # Returns remaining incomplete buffer.
  defp process_buffer(buffer, subscriber, max_frame_bytes) do
    {messages, invalid_lines, partial} = LineBuffer.drain_json(buffer)

    Enum.each(messages, fn message ->
      Kernel.send(subscriber, {:transport_event, message})
    end)

    Enum.each(invalid_lines, fn {:invalid_json, line} ->
      Logger.debug("Skipping invalid JSON", line_shape: LogSummary.describe(line))
    end)

    if byte_size(partial) <= max_frame_bytes, do: partial, else: ""
  end

  @doc false
  @spec append_frame(binary(), iodata(), pos_integer()) ::
          {:ok, binary()} | {:error, :frame_too_large}
  def append_frame(buffer, data, limit)
      when is_binary(buffer) and is_integer(limit) and limit > 0 do
    data = IO.iodata_to_binary(data)

    if byte_size(buffer) + byte_size(data) <= limit,
      do: {:ok, buffer <> data},
      else: {:error, :frame_too_large}
  end

  defp request_within_limit(message, limit) when byte_size(message) <= limit, do: :ok
  defp request_within_limit(_message, _limit), do: {:error, :frame_too_large}

  defp safe_env(opts) do
    opts
    |> PortEnvironment.base()
    |> Map.merge(PortEnvironment.normalize(Keyword.get(opts, :env, [])))
    |> PortEnvironment.to_port()
  end
end
