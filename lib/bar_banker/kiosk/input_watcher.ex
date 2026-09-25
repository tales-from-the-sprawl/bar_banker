defmodule BarBanker.Kiosk.InputWatcher do
  @moduledoc """
  Restarts the staff-facing `cog` browser window whenever a new input
  device (e.g. a USB keyboard) shows up after boot.

  weston's kiosk-shell only grants keyboard focus to a surface at *map*
  time. A keyboard plugged in before weston starts is present for that
  first map and works fine; libinput/weston happily notices one plugged in
  later too (confirmed in the log), but kiosk-shell never re-grants focus
  to the already-mapped surface for it, so its keystrokes go nowhere.
  There's no protocol-level way to ask weston to redo that from outside —
  the only remap trigger available to us is to kill and restart the `cog`
  process so it opens a brand new surface.

  `NervesUEvent` (started as part of `nerves_runtime`) publishes device
  changes as `PropertyTable` events; a `previous_value: nil` event means
  the property is new, i.e. the device just appeared.
  """
  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  @impl GenServer
  def init(_args) do
    NervesUEvent.subscribe([])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(
        %PropertyTable.Event{property: property, previous_value: nil, value: value},
        state
      )
      when not is_nil(value) do
    if input_device?(property) do
      Logger.info(
        "BarBanker.Kiosk.InputWatcher: new input device at #{inspect(property)}, remapping staff browser"
      )

      remap_staff_browser()
    end

    {:noreply, state}
  end

  def handle_info(_event, state), do: {:noreply, state}

  # Best-effort: sysfs paths for input devices always include an "input"
  # segment (e.g. .../input/input3/event4). Loosen/tighten this once real
  # property paths from the device are visible in the log above.
  defp input_device?(property), do: "input" in property

  defp remap_staff_browser() do
    with :ok <- Supervisor.terminate_child(BarBanker.Kiosk.Browsers, :staff),
         {:ok, _pid} <- Supervisor.restart_child(BarBanker.Kiosk.Browsers, :staff) do
      :ok
    else
      error ->
        Logger.warning(
          "BarBanker.Kiosk.InputWatcher: failed to remap staff browser: #{inspect(error)}"
        )
    end
  end
end
