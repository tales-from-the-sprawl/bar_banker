defmodule BarBanker.PN532.SPI do
  @moduledoc """
  SPI transport for the PN532 (see UM0701-02 §6.2.5, "SPI").

  The PN532 shifts data LSB-first, which `Circuits.SPI` supports natively via
  `lsb_first: true`, so no software bit-reversal is needed. Every logical
  operation below (status poll, data read, data write) is one SPI transfer,
  each with its own chip-select assertion, matching the PN532 datasheet's
  three SPI "functions": status read, data read, data write.
  """

  alias Circuits.SPI

  @default_speed_hz 500_000
  @poll_interval_ms 10

  @status_read 0x02
  @data_write 0x01
  @data_read 0x03
  @ready 0x01

  @type t :: SPI.Bus.t()

  @spec open(binary(), keyword()) :: {:ok, t()} | {:error, any()}
  def open(bus_name, opts \\ []) when is_binary(bus_name) do
    speed_hz = Keyword.get(opts, :speed_hz, @default_speed_hz)
    SPI.open(bus_name, speed_hz: speed_hz, lsb_first: true, mode: 0)
  end

  @spec wakeup(t()) :: :ok | {:error, any()}
  def wakeup(spi) do
    with {:ok, _reply} <- SPI.transfer(spi, <<0x00>>) do
      Process.sleep(10)
      :ok
    end
  end

  @spec wait_ready(t(), non_neg_integer()) :: :ok | {:error, :timeout | any()}
  def wait_ready(spi, timeout_ms \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_ready(spi, deadline)
  end

  @spec read_data(t(), pos_integer()) :: {:ok, binary()} | {:error, any()}
  def read_data(spi, count) when is_integer(count) and count > 0 do
    request = <<@data_read>> <> :binary.copy(<<0x00>>, count)

    with {:ok, <<_command_echo, data::binary>>} <- SPI.transfer(spi, request) do
      {:ok, data}
    end
  end

  @spec write_data(t(), binary()) :: :ok | {:error, any()}
  def write_data(spi, data) when is_binary(data) do
    with {:ok, _reply} <- SPI.transfer(spi, <<@data_write, data::binary>>) do
      :ok
    end
  end

  @spec poll_ready(t(), integer()) :: :ok | {:error, :timeout | any()}
  defp poll_ready(spi, deadline) do
    case SPI.transfer(spi, <<@status_read, 0x00>>) do
      {:ok, <<_status_ack, @ready>>} ->
        :ok

      {:ok, <<_status_ack, _not_ready>>} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@poll_interval_ms)
          poll_ready(spi, deadline)
        end

      {:error, _reason} = error ->
        error
    end
  end
end
