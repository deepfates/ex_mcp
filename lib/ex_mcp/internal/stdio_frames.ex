defmodule ExMCP.Internal.StdioFrames do
  @moduledoc """
  Frame I/O for protocols carried on standard streams.

  JSON-RPC frames are UTF-8 bytes. Erlang IO devices, by contrast, transcode
  according to the encoding they were opened with, and for the standard
  streams that depends on the environment the VM was started in. A process
  supervisor or host that starts the VM without `LANG`/`LC_ALL` gets a latin1
  device; writing a frame that contains an emoji or an accented name through
  such a device fails with `{:no_translation, :unicode, :latin1}`, and reading
  one through a unicode device re-encodes or rejects it. Either way the
  session dies mid-protocol.

  Every transport that speaks a protocol over a device therefore needs the
  same three things, and gets them here rather than deciding again:

    * `byte_mode/1` before either direction starts, so the device cannot
      transcode.
    * `write_frame/2` to put the bytes of one frame on the wire.
    * `read_line/1` and `read_bytes/2` to take bytes off it.

  Byte mode is `encoding: :latin1`, which is Erlang's name for "hand me the
  bytes". The frames themselves stay UTF-8; the device simply stops
  interpreting them.

  This module is internal.
  """

  @type device :: :stdio | :standard_io | :standard_error | IO.device()

  @doc """
  Puts a device into byte mode.

  Returns `{:error, :invalid_io_device}` rather than raising, so a transport
  can report an unusable device instead of failing during start-up.
  """
  @spec byte_mode(device()) :: :ok | {:error, :invalid_io_device}
  def byte_mode(device) do
    case :io.setopts(normalize(device), encoding: :latin1) do
      :ok -> :ok
      _other -> {:error, :invalid_io_device}
    end
  catch
    :exit, _ -> {:error, :invalid_io_device}
    :error, _ -> {:error, :invalid_io_device}
  end

  @doc "Writes one newline-terminated frame as raw bytes."
  @spec write_frame(device(), iodata()) :: :ok | {:error, term()}
  def write_frame(device, message) do
    :file.write(normalize(device), IO.iodata_to_binary([message, ?\n]))
  end

  @doc "Reads one newline-terminated frame as raw bytes."
  @spec read_line(device()) :: binary() | :eof | {:error, term()}
  def read_line(device), do: IO.binread(normalize(device), :line)

  @doc "Reads a fixed number of bytes."
  @spec read_bytes(device(), pos_integer()) :: binary() | :eof | {:error, term()}
  def read_bytes(device, count), do: IO.binread(normalize(device), count)

  # `:stdio` and `:standard_io` name the same device; callers use both.
  defp normalize(:stdio), do: :standard_io
  defp normalize(device), do: device
end
