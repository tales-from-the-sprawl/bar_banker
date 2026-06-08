defmodule BarBanker.NFC do
  use LibNFC.Presence

  require Logger

  @connstring "pn532_i2c:/dev/i2c-1"

  def subscribe_nfc() do
    Phoenix.PubSub.subscribe(BarBanker.PubSub, "nfc")
  end

  defp broadcast_nfc(message) do
    Phoenix.PubSub.broadcast(BarBanker.PubSub, "nfc", message)
  end

  @impl LibNFC.Presence
  def open_device(_client_state) do
    LibNFC.open(@connstring)
  end

  @impl LibNFC.Presence
  def handle_target_in(target, _) do
    uid = uid_hex(target["uid"])
    Logger.info("nfc: tag in: #{uid}")
    broadcast_nfc({:nfc, :in, uid})
    {:ok, uid}
  end

  @impl LibNFC.Presence
  def handle_target_out(uid) do
    Logger.info("nfc: tag out: #{uid}")
    broadcast_nfc({:nfc, :out, uid})
    {:ok, nil}
  end
end
