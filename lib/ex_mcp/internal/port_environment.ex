defmodule ExMCP.Internal.PortEnvironment do
  @moduledoc false

  @isolated_allowlist ~w(
    HOME LANG LOGNAME NIX_SSL_CERT_FILE PATH SHELL SSL_CERT_DIR SSL_CERT_FILE
    TEMP TMP TMPDIR TZ USER
  )

  @type value :: String.t() | false
  @type normalized :: %{optional(String.t()) => value()}

  @spec validate_policy(keyword()) :: :ok | {:error, {:invalid_environment_policy, term()}}
  def validate_policy(opts) do
    case Keyword.get(opts, :environment_policy, :isolated) do
      policy when policy in [:isolated, :inherit] -> :ok
      policy -> {:error, {:invalid_environment_policy, policy}}
    end
  end

  @spec base(keyword()) :: normalized()
  def base(opts) do
    case Keyword.get(opts, :environment_policy, :isolated) do
      :inherit -> %{}
      :isolated -> isolated_base()
    end
  end

  @spec normalize(map() | list() | term()) :: normalized()
  def normalize(env) when is_map(env) do
    Map.new(env, fn {name, value} -> {to_string(name), normalize_value(value)} end)
  end

  def normalize(env) when is_list(env) do
    Map.new(env, fn
      %{"name" => name, "value" => value} ->
        {to_string(name), normalize_value(value)}

      %{name: name, value: value} ->
        {to_string(name), normalize_value(value)}

      {name, value} ->
        {to_string(name), normalize_value(value)}
    end)
  end

  def normalize(_env), do: %{}

  @spec to_port(normalized()) :: [{charlist(), charlist() | false}]
  def to_port(env) when is_map(env) do
    Enum.map(env, fn
      {name, false} -> {to_charlist(name), false}
      {name, value} -> {to_charlist(name), to_charlist(value)}
    end)
  end

  defp isolated_base do
    parent_env = System.get_env()

    retained =
      Map.filter(parent_env, fn {name, _value} ->
        name in @isolated_allowlist or String.starts_with?(name, "LC_")
      end)
      |> sanitize_release_path(parent_env["RELEASE_ROOT"])

    parent_env
    |> Map.new(fn {name, _value} -> {name, false} end)
    |> Map.merge(retained)
  end

  # OTP releases prepend their private ERTS directories to PATH. Keeping those
  # entries after removing RELEASE_* makes a child `mix` or `elixir` invocation
  # resolve the release's `erl` executable and look for the parent's boot file.
  # An isolated child must retain the host PATH, not the release runtime path.
  defp sanitize_release_path(%{"PATH" => path} = env, release_root)
       when is_binary(path) and is_binary(release_root) and release_root != "" do
    release_root = Path.expand(release_root)

    path =
      path
      |> String.split(path_separator())
      |> Enum.reject(&release_path_entry?(&1, release_root))
      |> Enum.join(path_separator())

    Map.put(env, "PATH", path)
  end

  defp sanitize_release_path(env, _release_root), do: env

  defp release_path_entry?("", _release_root), do: false

  defp release_path_entry?(entry, release_root) do
    expanded = Path.expand(entry)

    Path.type(entry) == :absolute and
      (expanded == release_root or String.starts_with?(expanded, release_root <> "/") or
         String.starts_with?(expanded, release_root <> "\\"))
  end

  defp path_separator do
    case :os.type() do
      {:win32, _name} -> ";"
      _other -> ":"
    end
  end

  defp normalize_value(false), do: false
  defp normalize_value(value), do: to_string(value)
end
