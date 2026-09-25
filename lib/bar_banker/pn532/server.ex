defmodule BarBanker.PN532.Server do
  @moduledoc """
  Owns one PN532's SPI connection on behalf of all callers, so processes
  share a connection instead of each opening its own raw SPI handle, and
  reconnects automatically after failures or crashes instead of leaving a
  stale handle that blocks every future `BarBanker.PN532.open/2` on that bus.

  Request/response only: this process does not poll for tags itself, it
  just serializes access to the bus and keeps the connection alive.
  Reconnection is always-on and has no manual override — a bus that goes
  away (unplugged, or a crash) is retried on `@retry_interval_ms` forever.

  In low-power mode (the `:low_power` start option, or `set_low_power/2` at
  runtime) the reader is kept in `BarBanker.PN532.power_down/1` whenever it's idle,
  with its RF field off, and woken just for the duration of each request.
  A reader that fails to wake up is treated as a lost connection.

  `hold_awake/2` overrides low-power mode while a card is known to be
  present (`BarBanker.CardButton.Server` sets it from its button's level): a held
  reader is woken right away and kept awake between requests, so a card
  sitting in the slot stays powered and selected and requests skip the
  wake-up cost. Requests still wake a sleeping reader on demand, so a missed
  button edge only costs latency, never a failed request.
  """

  use GenServer

  alias BarBanker.PN532

  require Logger

  @retry_interval_ms 5_000
  @call_timeout 10_000
  @status_call_timeout 5_000

  @type status :: :connected | :disconnected

  @type t :: %__MODULE__{
          bus_name: String.t(),
          pn532: PN532.t() | nil,
          status: status(),
          error: term(),
          firmware_version: {byte(), byte(), byte(), byte()} | nil,
          low_power: boolean(),
          held: boolean(),
          asleep: boolean()
        }

  @enforce_keys [:bus_name]
  defstruct bus_name: nil,
            pn532: nil,
            status: :disconnected,
            error: nil,
            firmware_version: nil,
            low_power: false,
            held: false,
            asleep: false

  @doc """
  `opts`:
  * `:low_power` - start in low-power mode (see the moduledoc), defaults to `false`.
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(bus_name, opts \\ []) when is_binary(bus_name) do
    GenServer.start_link(__MODULE__, {bus_name, opts}, name: via(bus_name))
  end

  @doc "Current connection status, cached firmware version, last error (if any), and whether low-power mode is on."
  @spec status(String.t()) ::
          {status(), firmware_version :: {byte(), byte(), byte(), byte()} | nil, error :: term(),
           low_power :: boolean()}
          | {:error, :not_started}
  def status(bus_name), do: call(bus_name, :status, @status_call_timeout)

  @doc """
  Turns low-power mode on or off. Takes effect immediately: the reader is
  powered down (or woken) right away if it's connected and idle.
  """
  @spec set_low_power(String.t(), boolean()) :: :ok | {:error, :not_started | term()}
  def set_low_power(bus_name, enabled) when is_boolean(enabled) do
    call(bus_name, {:set_low_power, enabled}, @status_call_timeout)
  end

  @doc """
  Keeps the reader awake (`true`) or lets low-power mode power it down again
  when idle (`false`); see the moduledoc. Asynchronous, so a caller isn't
  blocked behind an in-flight scan, and a no-op if no server runs on the bus.
  """
  @spec hold_awake(String.t(), boolean()) :: :ok
  def hold_awake(bus_name, held) when is_boolean(held) do
    case Registry.lookup(BarBanker.PN532.Registry, bus_name) do
      [{pid, _value}] -> GenServer.cast(pid, {:hold_awake, held})
      [] -> :ok
    end
  end

  @doc "Waits for a passive target and reads its NDEF message, mirroring the driver's own composition."
  @spec scan(String.t()) ::
          {:ok, {uid :: binary(), sak :: byte(), ndef :: {:ok, binary()} | {:error, term()}}}
          | {:error, :not_connected | :not_started | term()}
  def scan(bus_name), do: call(bus_name, :scan, @call_timeout)

  @spec write_ndef(String.t(), binary(), byte(), binary()) ::
          :ok | {:error, :not_connected | :not_started | term()}
  def write_ndef(bus_name, uid, sak, message) do
    call(bus_name, {:write_ndef, uid, sak, message}, @call_timeout)
  end

  defp call(bus_name, message, timeout) do
    case Registry.lookup(BarBanker.PN532.Registry, bus_name) do
      [{pid, _value}] -> GenServer.call(pid, message, timeout)
      [] -> {:error, :not_started}
    end
  end

  defp via(bus_name), do: {:via, Registry, {BarBanker.PN532.Registry, bus_name}}

  @impl GenServer
  def init({bus_name, opts}) do
    Logger.metadata(pn532_bus: bus_name)
    low_power = Keyword.get(opts, :low_power, false)
    {:ok, %__MODULE__{bus_name: bus_name, low_power: low_power}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, attempt_connect(state)}

  @impl GenServer
  def handle_info(:retry_connect, state), do: {:noreply, attempt_connect(state)}

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, {state.status, state.firmware_version, state.error, state.low_power}, state}
  end

  def handle_call({:set_low_power, enabled}, _from, %__MODULE__{status: :disconnected} = state) do
    {:reply, :ok, %{state | low_power: enabled}}
  end

  def handle_call({:set_low_power, true}, _from, state) do
    {:reply, :ok, settle(%{state | low_power: true})}
  end

  def handle_call({:set_low_power, false}, _from, state) do
    state = %{state | low_power: false}

    case wake_up(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(_message, _from, %__MODULE__{status: :disconnected} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:scan, _from, state) do
    with_awake(state, fn pn532 ->
      with {:ok, {uid, sak}} <- PN532.read_passive_target(pn532) do
        {:ok, {uid, sak, PN532.read_ndef(pn532, uid, sak)}}
      end
    end)
  end

  def handle_call({:write_ndef, uid, sak, message}, _from, state) do
    with_awake(state, &PN532.write_ndef(&1, uid, sak, message))
  end

  @impl GenServer
  def handle_cast({:hold_awake, held}, %__MODULE__{status: :disconnected} = state) do
    {:noreply, %{state | held: held}}
  end

  def handle_cast({:hold_awake, held}, state) do
    {:noreply, settle(%{state | held: held})}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.pn532, do: PN532.close(state.pn532)
    :ok
  end

  # Runs `fun` against a woken-up reader and replies with its result, powering
  # the reader back down afterwards if it should sleep while idle.
  defp with_awake(state, fun) do
    case wake_up(state) do
      {:ok, state} ->
        result = fun.(state.pn532)
        {:reply, result, settle(state)}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Puts a connected, idle reader into the power state its low-power/held
  # flags call for. A failed wake-up has already been handled by `wake_up/1`.
  defp settle(%__MODULE__{low_power: true, held: false, asleep: false} = state),
    do: power_down(state)

  defp settle(%__MODULE__{asleep: true} = state) when not state.low_power or state.held do
    case wake_up(state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp settle(state), do: state

  defp wake_up(%__MODULE__{asleep: false} = state), do: {:ok, state}

  defp wake_up(state) do
    case PN532.wake_up(state.pn532) do
      :ok ->
        {:ok, %{state | asleep: false}}

      {:error, reason} ->
        Logger.warning("failed to wake up: #{inspect(reason)}")
        PN532.close(state.pn532)
        {:error, reason, attempt_connect(%{state | asleep: false})}
    end
  end

  # A reader that refuses to power down is left awake rather than treated as
  # disconnected: it still works, it just doesn't save power.
  defp power_down(state) do
    case PN532.power_down(state.pn532) do
      :ok ->
        %{state | asleep: true}

      {:error, reason} ->
        Logger.warning("failed to power down: #{inspect(reason)}")
        %{state | asleep: false}
    end
  end

  defp attempt_connect(state) do
    case PN532.open(state.bus_name) do
      {:ok, pn532} ->
        Logger.info("connected")

        firmware_version =
          case PN532.firmware_version(pn532) do
            {:ok, version} -> version
            {:error, _reason} -> nil
          end

        state = %{
          state
          | pn532: pn532,
            status: :connected,
            error: nil,
            firmware_version: firmware_version
        }

        settle(%{state | asleep: false})

      {:error, reason} ->
        if state.status == :connected do
          Logger.warning("lost connection: #{inspect(reason)}")
        end

        Process.send_after(self(), :retry_connect, @retry_interval_ms)
        %{state | pn532: nil, status: :disconnected, error: reason, firmware_version: nil}
    end
  end
end
