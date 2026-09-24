defmodule ExMCP.Server.OutputValidationDeadlineTest do
  @moduledoc """
  A tool's output is validated after its handler has run. When the validator
  misses its deadline, the caller must get the handler's result, not an error:
  the effect already happened, and an error invites a retry that repeats it.

  The validator is made slow with an ExJsonSchema custom format that sleeps
  past the shipped 100ms validation deadline. `test_helper.exs` widens that
  deadline for the rest of the suite, so these tests put the default back.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExMCP.Server.Tools.Registry

  defmodule SlowFormat do
    def validate("slow", _data) do
      Process.sleep(300)
      true
    end

    def validate(_format, _data), do: true
  end

  defmodule Server do
    use ExMCP.Server.Handler
    use ExMCP.Server.DSL

    tool "post", "Performs an effect, then returns output checked by a slow format" do
      output_schema(%{
        type: "object",
        properties: %{uri: %{type: "string", format: "slow"}},
        required: ["uri"]
      })

      run(fn _args, state ->
        send(state.effects, :posted)

        {:ok,
         %{
           content: [%{type: "text", text: "posted"}],
           structuredContent: %{uri: "at://did:plc:alice/app.bsky.feed.post/1"}
         }, state}
      end)
    end

    tool "wrong_shape", "Performs an effect, then returns output that does not match" do
      output_schema(%{
        type: "object",
        properties: %{uri: %{type: "string"}},
        required: ["uri"]
      })

      run(fn _args, state ->
        send(state.effects, :posted)

        {:ok, %{content: [%{type: "text", text: "posted"}], structuredContent: %{uri: 1}}, state}
      end)
    end
  end

  setup do
    restore = [
      {:ex_json_schema, :custom_format_validator,
       Application.fetch_env(:ex_json_schema, :custom_format_validator)},
      {:ex_mcp, :json_schema, Application.fetch_env(:ex_mcp, :json_schema)}
    ]

    Application.put_env(:ex_json_schema, :custom_format_validator, {SlowFormat, :validate})
    Application.delete_env(:ex_mcp, :json_schema)

    on_exit(fn ->
      for {app, key, previous} <- restore do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)
  end

  test "a DSL tool whose output validation times out returns its result" do
    log =
      capture_log(fn ->
        assert {:ok, response, _state} =
                 Server.handle_call_tool("post", %{}, %{effects: self()})

        send(self(), {:response, response})
      end)

    assert_received {:response, response}
    assert log =~ "Tool output returned unvalidated"
    assert_received :posted
    refute response[:isError]
    assert response.structuredContent.uri == "at://did:plc:alice/app.bsky.feed.post/1"
  end

  test "a DSL tool whose output does not match its schema is still an error" do
    assert {:ok, response, _state} =
             Server.handle_call_tool("wrong_shape", %{}, %{effects: self()})

    assert response.isError
  end

  test "a registry tool whose output validation times out returns its result" do
    {:ok, registry} = Registry.start_link(name: nil)

    :ok =
      Registry.register_tool(
        registry,
        %{
          name: "post",
          description: "posts",
          inputSchema: %{type: "object"},
          outputSchema: %{
            type: "object",
            properties: %{"uri" => %{type: "string", format: "slow"}}
          }
        },
        fn _args, state ->
          send(state.effects, :posted)
          {:ok, %{"uri" => "at://did:plc:alice/app.bsky.feed.post/1"}}
        end
      )

    capture_log(fn ->
      assert {:ok, %{"uri" => _}, _state} =
               Registry.call_tool(registry, "post", %{}, %{effects: self()})
    end)

    assert_received :posted
  end

  test "input validation keeps its deadline" do
    schema = %{type: "object", properties: %{"uri" => %{type: "string", format: "slow"}}}

    assert {:error, message} = ExMCP.Helpers.validate_tool_args(%{"uri" => "x"}, schema)
    assert message =~ "exceeded 100ms"
  end
end
