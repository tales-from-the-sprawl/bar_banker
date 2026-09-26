defmodule BarBanker.NFC do
  @moduledoc """
  App-facing NFC API on top of `BarBanker.PN532.Server`.

  The reader doesn't poll on its own: nothing touches the card field until a
  caller asks. `read_tag/0` checks for a card once, `wait_for_tag/0` keeps
  asking until one shows up — run it from a task (e.g. a LiveView
  `start_async/3`) and cancel/kill that task to stop polling.

  The I2C bus is read from `config :bar_banker, BarBanker.NFC, bus: "..."`
  and must also be listed in `BarBanker.PN532.Supervisor`'s `:buses`.
  """

  alias BarBanker.PN532.Server

  require Logger

  @default_bus "i2c-1"
  @retry_ms 1_000

  @doc "Checks for a card once, returning its UID as a lowercase hex string."
  @spec read_tag() :: {:ok, String.t()} | {:error, term()}
  def read_tag() do
    with {:ok, {uid, _sak}} <- Server.detect(bus()) do
      {:ok, Base.encode16(uid, case: :lower)}
    end
  end

  @doc """
  Polls the reader until a card is presented and returns its UID. Blocks
  indefinitely; reader errors (not connected, bus hiccups) are logged and
  retried rather than returned.
  """
  @spec wait_for_tag() :: String.t()
  def wait_for_tag() do
    case read_tag() do
      {:ok, uid} ->
        Logger.info("nfc: tag in: #{uid}")
        uid

      {:error, reason} when reason in [:timeout, :no_target_found] ->
        wait_for_tag()

      {:error, reason} ->
        Logger.debug("nfc: read failed (#{inspect(reason)}), retrying...")
        Process.sleep(@retry_ms)
        wait_for_tag()
    end
  end

  defp bus() do
    Application.get_env(:bar_banker, __MODULE__, [])
    |> Keyword.get(:bus, @default_bus)
  end
end
