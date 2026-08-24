defmodule ExMCP.Internal.PortEnvironmentTest do
  use ExUnit.Case, async: false

  alias ExMCP.Internal.PortEnvironment

  test "validates supported child environment policies" do
    assert :ok = PortEnvironment.validate_policy([])
    assert :ok = PortEnvironment.validate_policy(environment_policy: :isolated)
    assert :ok = PortEnvironment.validate_policy(environment_policy: :inherit)

    assert {:error, {:invalid_environment_policy, :unsafe}} =
             PortEnvironment.validate_policy(environment_policy: :unsafe)
  end

  test "normalizes supported environment shapes without losing explicit removals" do
    assert PortEnvironment.normalize(%{"BAR" => false, FOO: 1}) == %{
             "FOO" => "1",
             "BAR" => false
           }

    assert PortEnvironment.normalize([
             {"TUPLE", 2},
             %{name: :ATOM_MAP, value: true},
             %{"name" => "STRING_MAP", "value" => "value"}
           ]) == %{
             "TUPLE" => "2",
             "ATOM_MAP" => "true",
             "STRING_MAP" => "value"
           }

    assert PortEnvironment.normalize(:invalid) == %{}
  end

  test "encodes normalized values for Port.open/2" do
    assert PortEnvironment.to_port(%{"SET" => "value", "UNSET" => false})
           |> Map.new() == %{~c"SET" => ~c"value", ~c"UNSET" => false}
  end

  test "isolated base removes ambient variables while inherit starts empty" do
    sentinel = "EX_MCP_PORT_ENVIRONMENT_TEST_SECRET"
    previous = System.get_env(sentinel)
    System.put_env(sentinel, "ambient")

    on_exit(fn ->
      if is_binary(previous),
        do: System.put_env(sentinel, previous),
        else: System.delete_env(sentinel)
    end)

    assert PortEnvironment.base([])[sentinel] == false
    assert PortEnvironment.base(environment_policy: :inherit) == %{}
  end

  test "isolated base removes OTP release runtime entries from PATH" do
    release_root = Path.join(System.tmp_dir!(), "ex-mcp-release-root")
    outside_root = Path.join(release_root <> "-host", "bin")
    host_bin = Path.join(System.tmp_dir!(), "ex-mcp-host-bin")
    separator = path_separator()
    previous_root = System.get_env("RELEASE_ROOT")
    previous_path = System.get_env("PATH")

    System.put_env("RELEASE_ROOT", release_root)

    System.put_env(
      "PATH",
      Enum.join(
        [
          Path.join(release_root, "bin"),
          Path.join(release_root, "erts-1/bin"),
          outside_root,
          host_bin
        ],
        separator
      )
    )

    on_exit(fn ->
      restore_env("RELEASE_ROOT", previous_root)
      restore_env("PATH", previous_path)
    end)

    isolated = PortEnvironment.base(environment_policy: :isolated)

    assert isolated["RELEASE_ROOT"] == false
    assert isolated["PATH"] == Enum.join([outside_root, host_bin], separator)
  end

  defp restore_env(name, value) when is_binary(value), do: System.put_env(name, value)
  defp restore_env(name, nil), do: System.delete_env(name)

  defp path_separator do
    case :os.type() do
      {:win32, _name} -> ";"
      _other -> ":"
    end
  end
end
