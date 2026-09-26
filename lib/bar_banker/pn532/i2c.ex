defmodule BarBanker.PN532.I2C do
  @moduledoc """
  I2C transport for the PN532 (see UM0701-02 §6.2.4, "I2C"), ported from
  Adafruit's CircuitPython `adafruit_pn532.i2c` backend.

  Unlike SPI there are no status/data-read/data-write opcodes: a plain I2C
  write carries a command frame, and every I2C read starts with a status
  byte (`0x01` once the chip has a response ready) followed by the frame
  data. While it's busy the PN532 may also NACK its address outright, so a
  failed read while polling for readiness is treated as "not ready yet"
  rather than as an error.

  The PN532 relies on I2C clock stretching, which the Raspberry Pi's I2C
  controller handles poorly at the default 100 kHz; if reads come back
  garbled, lower the bus clock (e.g. `dtparam=i2c_arm_baudrate=10000` in
  `config.txt`).
  """

  alias Circuits.I2C

  @default_address 0x24
  @poll_interval_ms 10

  @ready 0x01

  @enforce_keys [:bus, :address]
  defstruct [:bus, :address]

  @type t :: %__MODULE__{bus: I2C.Bus.t(), address: I2C.address()}

  @doc """
  Opens `bus_name` (e.g. `"i2c-1"`). `opts`:
  * `:address` - the PN532's 7-bit I2C address, defaults to `0x24`.
  """
  @spec open(binary(), keyword()) :: {:ok, t()} | {:error, any()}
  def open(bus_name, opts \\ []) when is_binary(bus_name) do
    address = Keyword.get(opts, :address, @default_address)

    with {:ok, bus} <- I2C.open(bus_name) do
      {:ok, %__MODULE__{bus: bus, address: address}}
    end
  end

  @spec close(t()) :: :ok
  def close(i2c), do: I2C.close(i2c.bus)

  @doc """
  Wakes the chip from power-down: the PN532 wakes on its own I2C address
  match, but NACKs that first transaction, so the read's result is ignored.
  """
  @spec wakeup(t()) :: :ok
  def wakeup(i2c) do
    _ = I2C.read(i2c.bus, i2c.address, 1)
    Process.sleep(10)
    :ok
  end

  @spec wait_ready(t(), non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_ready(i2c, timeout_ms \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_ready(i2c, deadline)
  end

  @doc "Reads `count` bytes of frame data, stripping the leading status byte."
  @spec read_data(t(), pos_integer()) :: {:ok, binary()} | {:error, :busy | any()}
  def read_data(i2c, count) when is_integer(count) and count > 0 do
    case I2C.read(i2c.bus, i2c.address, count + 1) do
      {:ok, <<@ready, data::binary>>} -> {:ok, data}
      {:ok, _not_ready} -> {:error, :busy}
      {:error, _reason} = error -> error
    end
  end

  @spec write_data(t(), binary()) :: :ok | {:error, any()}
  def write_data(i2c, data) when is_binary(data) do
    I2C.write(i2c.bus, i2c.address, data)
  end

  @spec poll_ready(t(), integer()) :: :ok | {:error, :timeout}
  defp poll_ready(i2c, deadline) do
    case I2C.read(i2c.bus, i2c.address, 1) do
      {:ok, <<@ready>>} ->
        :ok

      _not_ready_or_nack ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@poll_interval_ms)
          poll_ready(i2c, deadline)
        end
    end
  end
end
