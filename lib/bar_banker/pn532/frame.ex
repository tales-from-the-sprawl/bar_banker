defmodule BarBanker.PN532.Frame do
  @moduledoc """
  PN532 host-controller-interface framing: building command frames and
  parsing/validating response frames, independent of the transport bus.

  Frame layout (see UM0701-02 §6.2): `00 00 FF LEN LCS <TFI PD0..PDn> DCS 00`,
  where `LEN` covers `TFI` plus the parameter/data bytes, `LCS` is the
  two's-complement checksum of `LEN`, and `DCS` is the two's-complement
  checksum of `TFI` and the data bytes (so that `sum(TFI..PDn) + DCS ≡ 0
  (mod 256)`).
  """

  @preamble 0x00
  @start_code_1 0x00
  @start_code_2 0xFF
  @postamble 0x00

  @host_to_pn532 0xD4
  @pn532_to_host 0xD5

  @ack_frame <<0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00>>

  @type reason ::
          :invalid_preamble | :length_checksum_mismatch | :data_checksum_mismatch | :truncated

  @doc "The fixed 6-byte ACK frame the PN532 sends to acknowledge a command."
  @spec ack_frame() :: binary()
  def ack_frame(), do: @ack_frame

  @doc "Whether `binary` is exactly the fixed ACK frame."
  @spec ack?(binary()) :: boolean()
  def ack?(binary), do: binary == @ack_frame

  @doc """
  Builds a command frame ready to write to the bus: the host-to-PN532
  envelope (`TFI` + `command` + `params`) wrapped in the preamble/length/
  checksum/postamble framing.
  """
  @spec encode(byte(), binary()) :: binary()
  def encode(command, params \\ <<>>) when is_integer(command) and is_binary(params) do
    data = <<@host_to_pn532, command, params::binary>>
    len = byte_size(data)
    lcs = checksum(<<len>>)
    dcs = checksum(data)

    <<@preamble, @start_code_1, @start_code_2, len, lcs, data::binary, dcs, @postamble>>
  end

  @doc """
  Parses a raw response read from the bus: skips leading padding, validates
  the start code, length checksum, and data checksum, and returns the
  `TFI` + response payload (without the trailing `DCS`/postamble) on success.
  """
  @spec decode(binary()) :: {:ok, binary()} | {:error, reason()}
  def decode(binary) when is_binary(binary) do
    with {:ok, rest} <- skip_padding(binary),
         {:ok, len, rest} <- take_length(rest) do
      take_data(rest, len)
    end
  end

  @doc "Whether `payload` (as returned by `decode/1`) is a valid response to `command`."
  @spec response_to?(binary(), byte()) :: boolean()
  def response_to?(<<@pn532_to_host, response_command, _rest::binary>>, command) do
    response_command == command + 1
  end

  def response_to?(_payload, _command), do: false

  @doc "Strips the `TFI`/command-echo header from a decoded response payload."
  @spec response_data(binary()) :: binary()
  def response_data(<<@pn532_to_host, _response_command, data::binary>>), do: data

  @spec skip_padding(binary()) :: {:ok, binary()} | {:error, reason()}
  defp skip_padding(<<@preamble, rest::binary>>), do: skip_padding(rest)
  defp skip_padding(<<@start_code_2, rest::binary>>), do: {:ok, rest}
  defp skip_padding(_binary), do: {:error, :invalid_preamble}

  @spec take_length(binary()) :: {:ok, byte(), binary()} | {:error, reason()}
  defp take_length(<<len, lcs, rest::binary>>) do
    if checksum(<<len>>) == lcs do
      {:ok, len, rest}
    else
      {:error, :length_checksum_mismatch}
    end
  end

  defp take_length(_binary), do: {:error, :truncated}

  @spec take_data(binary(), byte()) :: {:ok, binary()} | {:error, reason()}
  defp take_data(binary, len) when byte_size(binary) >= len + 1 do
    <<data::binary-size(^len), dcs, _rest::binary>> = binary

    if checksum(data) == dcs do
      {:ok, data}
    else
      {:error, :data_checksum_mismatch}
    end
  end

  defp take_data(_binary, _len), do: {:error, :truncated}

  @spec checksum(binary()) :: byte()
  defp checksum(binary) do
    sum = for(<<byte <- binary>>, do: byte) |> Enum.sum()
    Bitwise.band(-sum, 0xFF)
  end
end
