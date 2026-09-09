defmodule ExMCP.Stdio do
  @moduledoc """
  Frame I/O for protocols carried on standard streams.

  JSON-RPC frames are UTF-8 bytes. Erlang IO devices, by contrast, transcode
  according to the encoding they were opened with, which depends on the
  environment's locale: an OTP release started by launchd or systemd, or a host
  that passes a minimal environment, gets a latin1 device. Writing a frame
  containing an emoji or a non-ASCII handle through such a device exits with
  `{:no_translation, :unicode, :latin1}`, killing the session mid-protocol.

  Every transport that speaks a protocol over a device therefore needs the same
  three things, and gets them here rather than deciding again:

  - `byte_mode/1` before either direction starts, so the VM cannot transcode.
  - `write_frame/2` to put bytes on the wire.
  - `read_line/1` and `read_bytes/2` to take bytes off it.

  Byte mode is `encoding: :latin1`, which is Erlang's name for "hand me the
  bytes". The frames themselves remain UTF-8; the device simply stops
  interpreting them.
  """

  @type device :: :standard_io | :standard_error | IO.device()

  @doc """
  Put a device into byte mode.

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

  @doc "Write one frame, terminated by a newline, as raw bytes."
  @spec write_frame(device(), iodata()) :: :ok | {:error, term()}
  def write_frame(device, message) do
    :file.write(normalize(device), IO.iodata_to_binary([message, ?\n]))
  end

  @doc "Read one newline-terminated frame as raw bytes."
  @spec read_line(device()) :: binary() | :eof | {:error, term()}
  def read_line(device), do: IO.binread(normalize(device), :line)

  @doc "Read a fixed number of bytes."
  @spec read_bytes(device(), pos_integer()) :: binary() | :eof | {:error, term()}
  def read_bytes(device, count), do: IO.binread(normalize(device), count)

  # `:stdio` and `:standard_io` name the same device; transports use both.
  defp normalize(:stdio), do: :standard_io
  defp normalize(device), do: device
end
