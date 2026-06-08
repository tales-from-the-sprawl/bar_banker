defmodule BarBanker.Nfc do
  @moduledoc """
  Reads a PN532 chip over I2C.
  Spawns a python process to do the reading.
  Because life is pain and suffering...
  """
  use GenServer

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def read() do
    GenServer.call(__MODULE__, :read, :infinity)
  end

  def write(data) do
    GenServer.call(__MODULE__, {:write, data})
  end

  @impl GenServer
  def init(_init_arg) do
    port = Port.open({:spawn, "uv run nfc.py"}, [:binary, cd: "/home/trinity/dev/bar-banker"])

    {:ok, {port}}
  end

  @impl GenServer
  def handle_call(:read, _from, {port}) do
    send(port, {self(), {:command, "read\n"}})

    msg =
      receive do
        {^port, {:data, value}} -> parse_data(value)
      end

    data =
      msg["data"]
      |> parse_tlv()
      |> parse_ndef()
      |> Enum.map(fn {v, _} -> v end)

    msg = %{msg | "data" => data}

    {:reply, msg, {port}}
  end

  @impl GenServer
  def handle_call({:write, data}, _from, {port}) do
    send(port, {self(), {:command, "write\n"}})
    send(port, {self(), {:command, data}})

    msg =
      receive do
        {^port, {:data, "ok"}} -> :ok
        {^port, {:data, "error"}} -> :error
      end

    {:reply, msg, {port}}
  end

  defp parse_data(data) do
    data
    |> String.split(";")
    |> Enum.filter(&(&1 != "\n"))
    |> Enum.map(&String.split(&1, ":"))
    |> Enum.into(%{}, fn [k, v] -> {k, Base.decode64!(v)} end)
  end

  defp parse_tlv(data, acc \\ []) do
    case TLV.decode(data) do
      {rec, rest} -> parse_tlv(rest, [rec | acc])
      :no_tlv -> Enum.reverse(acc)
    end
  end

  defp parse_ndef(data, acc \\ [])

  defp parse_ndef(
         [%TLV{tag: 1, value: <<160, 12, 52>>, indefinite_length: false} | rest],
         acc
       ) do
    parse_ndef(rest, acc)
  end

  defp parse_ndef([%TLV{tag: 3, value: ndef_data} | rest], acc) do
    parse_ndef(rest, [NDEF.parse_short_record(ndef_data) | acc])
  end

  defp parse_ndef([%TLV{tag: 254, value: [], indefinite_length: false} | _], acc) do
    Enum.reverse(acc)
  end
end
