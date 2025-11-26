defmodule BarBanker.Keypad do
  require Logger
  alias BarBanker.Utils
  alias Circuits.GPIO
  use GenServer

  defstruct pins: %{}, held_keys: [], buffer: [], timer: nil

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @keymap {
    {:"1", :"2", :"3", :A},
    {:"4", :"5", :"6", :B},
    {:"7", :"8", :"9", :C},
    {:*, :"0", :"#", :D}
  }

  @rows [6, 13, 19, 26]
  @cols [12, 16, 20, 21]

  @debounce_window 10

  @impl GenServer
  def init(_init_arg) do
    pins = setup_gpio()
    send(self(), :scan)

    {:ok, %__MODULE__{pins: pins}}
  end

  defp setup_gpio() do
    row_pins = @rows |> Enum.map(&open_input_pin!/1)
    col_pins = @cols |> Enum.map(&open_output_pin!/1)

    %{
      row_pins: row_pins,
      col_pins: col_pins
    }
  end

  defp open_input_pin!(pin) do
    {:ok, ref} = GPIO.open(pin, :input, pull_mode: :pullup)
    ref
  end

  defp open_output_pin!(pin) do
    {:ok, ref} = GPIO.open(pin, :output, initial_value: 1)
    ref
  end

  @impl GenServer
  def handle_info(:flush, %__MODULE__{} = state) do
    state.buffer
    |> Enum.reverse()
    |> Utils.dedupe_events()
    |> Enum.each(fn
      {:pressed, key} ->
        Logger.debug("Pressed #{key}")

      {:released, key} ->
        Logger.debug("Released #{key}")
    end)

    {:noreply, %{state | buffer: [], timer: nil}}
  end

  @impl GenServer
  def handle_info(
        :scan,
        %__MODULE__{pins: pins, held_keys: held_keys, buffer: orig_buffer} = state
      ) do
    keys = scan_gpio(pins)
    released = held_keys -- keys
    pressed = keys -- held_keys

    buffer = Enum.reduce(released, orig_buffer, fn key, acc -> [{:released, key} | acc] end)
    buffer = Enum.reduce(pressed, buffer, fn key, acc -> [{:pressed, key} | acc] end)

    state =
      if orig_buffer != buffer do
        set_debounce_timer(state)
      else
        state
      end

    Process.send_after(self(), :scan, 2)

    {:noreply, %{state | held_keys: keys, buffer: buffer}}
  end

  defp scan_gpio(%{row_pins: rows, col_pins: cols}) do
    for {col, i} <- Enum.with_index(cols), reduce: [] do
      acc ->
        GPIO.write(col, 0)

        res =
          for {row, j} <- Enum.with_index(rows), reduce: acc do
            acc ->
              if GPIO.read(row) == 0 do
                [
                  @keymap
                  |> elem(j)
                  |> elem(i)
                  | acc
                ]
              else
                acc
              end
          end

        GPIO.write(col, 1)
        res
    end
  end

  defp set_debounce_timer(%__MODULE__{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :flush, @debounce_window)}
  end

  defp set_debounce_timer(%__MODULE__{timer: timer} = state) do
    Process.cancel_timer(timer)
    set_debounce_timer(%{state | timer: nil})
  end
end
