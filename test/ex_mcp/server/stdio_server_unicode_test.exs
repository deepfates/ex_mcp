defmodule ExMCP.Server.StdioServerUnicodeTest do
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "cold C-locale stdio preserves UTF-8 bytes and stops on EOF" do
    dir = Path.join(System.tmp_dir!(), "ex-mcp-stdio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    script = Path.join(dir, "server.exs")
    input = Path.join(dir, "input.jsonl")

    File.write!(script, """
    # Reproduce the release device mode; Elixir CLI can force Unicode even in C.
    :ok = :io.setopts(:standard_io, encoding: :latin1)
    defmodule EchoServer do
      use ExMCP.Server.Handler
      use ExMCP.Server.DSL, name: "echo", version: "1"
      tool "echo", "Echo Unicode" do
        param :text, :string, required: true
        run fn args, state ->
          # Echo alone can hide paired input/output transcoding errors.
          if args.text != "café 日本語 🪁", do: raise("input was transcoded")
          {:ok, "café 日本語 🪁", state}
        end
      end
    end
    {:ok, pid} = EchoServer.start_link(transport: :stdio)
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> raise inspect(reason)
    after
      10_000 -> raise "EOF did not close transport"
    end
    """)

    value = "café 日本語 🪁"

    requests = [
      %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-03-26",
          capabilities: %{},
          clientInfo: %{name: "test", version: "1"}
        }
      },
      %{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: %{name: "echo", arguments: %{text: value}}
      }
    ]

    File.write!(input, Enum.map(requests, &[Jason.encode!(&1), "\n"]))
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])

    {output, code} =
      System.cmd(
        "sh",
        [
          "-c",
          "exec \"$@\" < \"$STDIO_TEST_INPUT\"",
          "stdio-test",
          System.find_executable("elixir")
        ] ++ paths ++ [script],
        env: [{"LANG", "C"}, {"LC_ALL", "C"}, {"MIX_ENV", "test"}, {"STDIO_TEST_INPUT", input}]
      )

    assert code == 0
    responses = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert length(responses) == 2
    assert %{"id" => 2, "result" => %{"content" => [%{"text" => ^value}]}} = List.last(responses)
  end
end
