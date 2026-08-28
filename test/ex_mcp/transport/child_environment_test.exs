defmodule ExMCP.Transport.ChildEnvironmentTest do
  use ExUnit.Case, async: true

  alias ExMCP.Transport

  test "isolates ambient values and applies explicit overrides" do
    name = "EX_MCP_CHILD_ENV_#{System.unique_integer([:positive])}"
    previous = System.get_env(name)
    System.put_env(name, "ambient-secret")

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)

    assert {:ok, environment} =
             Transport.child_environment(
               environment_policy: :isolated,
               env: [{name, "explicit"}, {"REMOVE_ME", false}]
             )

    assert {name, "explicit"} in environment
    assert {"REMOVE_ME", false} in environment

    assert Enum.all?(environment, fn
             {key, value} -> is_binary(key) and (is_binary(value) or value == false)
           end)
  end

  test "inherit returns only explicit overrides" do
    assert {:ok, [{"VISIBLE", "yes"}]} =
             Transport.child_environment(
               environment_policy: :inherit,
               env: [{"VISIBLE", "yes"}]
             )
  end

  test "rejects an unknown environment policy" do
    assert {:error, {:invalid_environment_policy, :ambient}} =
             Transport.child_environment(environment_policy: :ambient)
  end
end
