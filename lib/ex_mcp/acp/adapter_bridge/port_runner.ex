defmodule ExMCP.ACP.AdapterBridge.PortRunner do
  @moduledoc false

  alias ExMCP.Internal.{OwnedProcess, PortEnvironment}

  @session_vars_to_clear ~w(
    CLAUDE_CODE_ENTRYPOINT CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR
    CLAUDECODE CODEX_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY
    GOOGLE_API_KEY PI_API_KEY MIX_ENV MIX_TARGET
  )

  @spec open(String.t(), [String.t()], keyword(), module()) ::
          {:ok, OwnedProcess.t()} | {:error, term()}
  def open(cmd, args, opts, adapter_mod) do
    with :ok <- PortEnvironment.validate_policy(opts),
         executable when is_binary(executable) <- System.find_executable(cmd) do
      do_open(executable, args, opts, adapter_mod)
    else
      nil -> {:error, {:executable_not_found, cmd}}
      {:error, _reason} = error -> error
    end
  end

  defp do_open(executable, args, opts, adapter_mod) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    OwnedProcess.open(executable, args,
      cd: cwd,
      env: safe_env(opts, adapter_mod),
      inherit_environment: Keyword.get(opts, :environment_policy, :isolated) == :inherit
    )
  end

  @spec command(OwnedProcess.t(), iodata()) :: :ok | {:error, term()}
  def command(process, data), do: OwnedProcess.command(process, data)

  @spec close(OwnedProcess.t() | nil) :: :ok
  def close(process), do: OwnedProcess.close(process)

  @spec safe_env(keyword(), module()) :: [{charlist(), charlist() | false}]
  def safe_env(opts, adapter_mod) do
    opts
    |> PortEnvironment.base()
    |> Map.merge(Map.new(@session_vars_to_clear, &{&1, false}))
    |> Map.put("TERM", "dumb")
    |> Map.merge(adapter_env(opts, adapter_mod))
    |> PortEnvironment.to_port()
  end

  defp adapter_env(opts, adapter_mod) do
    adapter_default_env =
      if function_exported?(adapter_mod, :env, 1) do
        adapter_mod.env(opts)
      else
        []
      end

    adapter_default_env
    |> PortEnvironment.normalize()
    |> Map.merge(opts |> Keyword.get(:env, []) |> PortEnvironment.normalize())
    |> maybe_put_api_key(Keyword.get(opts, :api_key))
  end

  defp maybe_put_api_key(env, nil), do: env
  defp maybe_put_api_key(env, api_key), do: Map.put(env, "PI_API_KEY", to_string(api_key))
end
