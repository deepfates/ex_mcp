defmodule ExMCP.Internal.StdioFramesTest do
  use ExUnit.Case, async: true

  alias ExMCP.Internal.StdioFrames

  @frame ~s({"jsonrpc":"2.0","result":{"text":"café 日本語 🪁"}})

  setup do
    dir = Path.join(System.tmp_dir!(), "ex-mcp-frames-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp device(dir, encoding) do
    path = Path.join(dir, "frame-#{System.unique_integer([:positive])}")
    {:ok, io} = File.open(path, [:write, :read, {:encoding, encoding}])
    {io, path}
  end

  test "a frame survives a device the environment left in unicode mode", ctx do
    {io, path} = device(ctx.dir, :unicode)
    assert :ok = StdioFrames.byte_mode(io)
    assert :ok = StdioFrames.write_frame(io, @frame)
    assert File.read!(path) == @frame <> "\n"
  end

  test "a frame survives a device the environment left in latin1 mode", ctx do
    {io, path} = device(ctx.dir, :latin1)
    assert :ok = StdioFrames.byte_mode(io)
    assert :ok = StdioFrames.write_frame(io, @frame)
    assert File.read!(path) == @frame <> "\n"
  end

  test "a frame is read back as the bytes that were written", ctx do
    {io, _path} = device(ctx.dir, :unicode)
    :ok = StdioFrames.byte_mode(io)
    :ok = StdioFrames.write_frame(io, @frame)
    {:ok, 0} = :file.position(io, :bof)

    assert StdioFrames.read_line(io) == @frame <> "\n"
  end

  test "an unusable device is reported rather than raised" do
    assert {:error, :invalid_io_device} = StdioFrames.byte_mode(:no_such_device)
  end

  test ":stdio and :standard_io name one device" do
    assert StdioFrames.byte_mode(:stdio) == StdioFrames.byte_mode(:standard_io)
  end
end
