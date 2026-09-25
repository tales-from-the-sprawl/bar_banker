defmodule BarBanker.Keypad do
  @moduledoc """
  GenServer driver for a 4x4 matrix keypad (12-key keypad plus `A`/`B`/`C`/`D`
  keys) wired to GPIO rows 6/13/19/26 and columns 12/16/20/21.

  Rows are opened as open-drain outputs with an internal pull-up, and columns as
  inputs with an internal pull-up. Every 10 ms, each row is pulled low in turn
  and the column that reads low identifies the pressed key. Open-drain rows are
  only ever driven low, so two rows shorted together (or two keys in the same
  column pressed at once) can't make two outputs fight each other.

  A key has to read the same for 3 consecutive scans (~30 ms) before it
  counts. On each debounced press, broadcasts, over `BarBanker.PubSub` on
  `#{inspect(__MODULE__)}.topic/0`, a `{:keypad, key}` message.
  """

  use GenServer

  alias Circuits.GPIO

  @row_pins [6, 13, 19, 26]
  @col_pins [12, 16, 20, 21]
  @scan_interval_ms 10
  @debounce_scans 3
  @topic "keypad"

  @matrix [
    ["1", "2", "3", "A"],
    ["4", "5", "6", "B"],
    ["7", "8", "9", "C"],
    ["*", "0", "#", "D"]
  ]

  defstruct row_pins: [], col_pins: [], pressed: nil, candidate: nil, candidate_count: 0

  @spec start_link([GenServer.option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  def subscribe_keypad() do
    Phoenix.PubSub.subscribe(BarBanker.PubSub, @topic)
  end

  @impl GenServer
  def init([]) do
    state = %__MODULE__{
      row_pins: Enum.map(@row_pins, &open_row_pin!/1),
      col_pins: Enum.map(@col_pins, &open_col_pin!/1)
    }

    schedule_scan()
    {:ok, state}
  end

  @spec open_row_pin!(pos_integer()) :: GPIO.Handle.t()
  defp open_row_pin!(pin_num) do
    {:ok, pin} =
      GPIO.open(pin_num, :output, initial_value: 1, drive_mode: :open_drain, pull_mode: :pullup)

    pin
  end

  @spec open_col_pin!(pos_integer()) :: GPIO.Handle.t()
  defp open_col_pin!(pin_num) do
    {:ok, pin} = GPIO.open(pin_num, :input, pull_mode: :pullup)
    pin
  end

  @impl GenServer
  def handle_info(:scan, state) do
    schedule_scan()
    {:noreply, debounce(state, scan(state))}
  end

  defp schedule_scan(), do: Process.send_after(self(), :scan, @scan_interval_ms)

  # Returns the first pressed key found, or nil if none is pressed.
  @spec scan(%__MODULE__{}) :: String.t() | nil
  defp scan(state) do
    state.row_pins
    |> Enum.zip(@matrix)
    |> Enum.find_value(fn {row, keys} ->
      GPIO.write(row, 0)
      col_index = Enum.find_index(state.col_pins, &(GPIO.read(&1) == 0))
      GPIO.write(row, 1)

      col_index && Enum.at(keys, col_index)
    end)
  end

  defp debounce(%__MODULE__{candidate: key} = state, key) do
    count = state.candidate_count + 1

    if count == @debounce_scans and key != state.pressed do
      if key, do: Phoenix.PubSub.broadcast(BarBanker.PubSub, @topic, {:keypad, key})
      %{state | pressed: key, candidate_count: count}
    else
      %{state | candidate_count: count}
    end
  end

  defp debounce(state, key), do: %{state | candidate: key, candidate_count: 1}
end
