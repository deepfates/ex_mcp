defmodule ExMCP.StdioTest do
  use ExUnit.Case, async: true

  @frame ~s({"jsonrpc":"2.0","result":{"text":"café 日本語 🪁"}})

  setup do
    dir = Path.join(System.tmp_dir!(), "ex-mcp-stdio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp device(dir, mode) do
    path = Path.join(dir, "frame-#{System.unique_integer([:positive])}")
    {:ok, io} = File.open(path, [:write, :read, mode])
    {io, path}
  end

  test "a frame survives a device the environment left in unicode mode", ctx do
    {io, path} = device(ctx.dir, :utf8)
    assert :ok = ExMCP.Stdio.byte_mode(io)
    assert :ok = ExMCP.Stdio.write_frame(io, @frame)
    assert File.read!(path) == @frame <> "\n"
  end

  test "a frame survives a device the environment left in latin1 mode", ctx do
    {io, path} = device(ctx.dir, :latin1)
    assert :ok = ExMCP.Stdio.byte_mode(io)
    assert :ok = ExMCP.Stdio.write_frame(io, @frame)
    assert File.read!(path) == @frame <> "\n"
  end

  test "bytes are neither transcoded nor double-encoded", ctx do
    {io, path} = device(ctx.dir, :utf8)
    :ok = ExMCP.Stdio.byte_mode(io)
    :ok = ExMCP.Stdio.write_frame(io, @frame)

    # The exact bytes Jason produced, not a re-encoding of them.
    assert File.read!(path) |> :binary.part(0, byte_size(@frame)) == @frame
    assert String.valid?(File.read!(path))
  end

  test "an unusable device is reported rather than raised" do
    assert {:error, :invalid_io_device} = ExMCP.Stdio.byte_mode(:no_such_device)
  end

  test ":stdio and :standard_io name one device" do
    # Both spellings appear across the transports; they must not diverge.
    assert ExMCP.Stdio.byte_mode(:stdio) == ExMCP.Stdio.byte_mode(:standard_io)
  end
end
