defmodule BarBanker.Finance do
  @moduledoc """
  Point-of-sale charging: debits the card presented at the kiosk's NFC reader
  and credits the shop's own ledger account, `"trinity_taskbar"`.

  A **sincard** carries a `"sin:xxxx"` handle; its balance lives remotely, so
  charging it is a single `BarBanker.BotClient.transfer/3,4` to the shop.

  A **credstick** carries its balance as a plain integer string directly in its
  NDEF text record. Charging it takes two separate operations that can't be done
  atomically: rewriting the card with the reduced balance (via
  `BarBanker.PN532.Server.write_ndef/4`), then minting the same amount into the
  shop's account (a ledger transfer with no sender). The card is always debited
  first, and if the ledger credit fails the card's old balance is written back,
  so a partial failure never creates money - at worst it's destroyed and
  reported as needing manual reconciliation.
  """

  alias BarBanker.BotClient
  alias BarBanker.NDEF
  alias BarBanker.NFC
  alias BarBanker.PN532.Server, as: PN532Server

  require Logger

  @receiver "trinity_taskbar"
  @retry_ms 1_000

  @type card :: {:sin, String.t()} | {:cred, non_neg_integer()}
  @type locator :: {bus :: String.t(), uid :: binary(), sak :: byte()}
  @opaque scanned_card :: {card(), locator()}

  @type reconciliation_error ::
          {:reconciliation_required,
           %{
             bus: String.t(),
             uid: binary(),
             sak: byte(),
             expected_balance: non_neg_integer(),
             credit_error: term(),
             compensation_error: term()
           }}

  @type charge_error ::
          :invalid_amount
          | :insufficient_funds
          | :card_not_recognized
          | :no_text_record
          | reconciliation_error()
          | term()

  @doc "The ledger handle every charge is paid to."
  @spec receiver() :: String.t()
  def receiver(), do: @receiver

  @doc "Classifies a decoded NDEF text record as a sincard handle or a credstick balance."
  @spec parse_card({String.t(), String.t()}) :: {:ok, card()} | {:error, :card_not_recognized}
  def parse_card({_language, "sin:" <> id}) do
    {:ok, {:sin, id}}
  end

  def parse_card({_language, content}) do
    case Integer.parse(content) do
      {value, ""} when value >= 0 -> {:ok, {:cred, value}}
      _other -> {:error, :card_not_recognized}
    end
  end

  @doc """
  Decodes a scanned tag's NDEF message (as returned by `BarBanker.PN532.Server.scan/1`)
  into a `card/0`, passing through a scan-level NDEF read error unchanged.
  """
  @spec decode_card({:ok, binary()} | {:error, term()}) ::
          {:ok, card()} | {:error, charge_error()}
  def decode_card({:error, reason}), do: {:error, reason}

  def decode_card({:ok, raw_ndef}) do
    with {:ok, records} <- NDEF.decode_records(raw_ndef),
         %NDEF.Record{} = text_record <- Enum.find(records, :no_text_record, &(&1.type == "T")),
         {:ok, text_tuple} <- NDEF.decode_text(text_record) do
      parse_card(text_tuple)
    else
      :no_text_record -> {:error, :no_text_record}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Checks the kiosk's NFC reader (the bus configured for `BarBanker.NFC`) once
  and decodes the card on it, ready to pass to `charge/2`.
  """
  @spec read_card() :: {:ok, scanned_card()} | {:error, charge_error()}
  def read_card() do
    bus = NFC.bus()

    with {:ok, scan} <- PN532Server.scan(bus) do
      decode_scan(bus, scan)
    end
  end

  @doc """
  Polls the reader until a card is presented, then decodes it like
  `read_card/0`. Blocks indefinitely: reader errors (no card yet, reader not
  connected, bus hiccups) are retried, but a card that was found and can't be
  read or recognized is returned as an error. Run it from a task and cancel
  that task to stop polling.
  """
  @spec wait_for_card() :: {:ok, scanned_card()} | {:error, charge_error()}
  def wait_for_card() do
    bus = NFC.bus()

    case PN532Server.scan(bus) do
      {:ok, scan} ->
        decode_scan(bus, scan)

      {:error, reason} when reason in [:timeout, :no_target_found] ->
        wait_for_card()

      {:error, reason} ->
        Logger.debug("finance: card read failed (#{inspect(reason)}), retrying...")
        Process.sleep(@retry_ms)
        wait_for_card()
    end
  end

  @doc """
  Charges `amount` to a card from `read_card/0` or `wait_for_card/0`, paying it
  to `receiver/0`. A credstick must still be on the reader, since its new
  balance is written back to it.

  Returns the ledger's `{:ok, {message, amount}}` on success.
  """
  @spec charge(scanned_card(), integer()) :: {:ok, term()} | {:error, charge_error()}
  def charge(_scanned_card, amount) when not is_integer(amount) or amount <= 0,
    do: {:error, :invalid_amount}

  def charge({card, locator}, amount), do: charge_card(card, locator, amount)

  @spec decode_scan(String.t(), {binary(), byte(), {:ok, binary()} | {:error, term()}}) ::
          {:ok, scanned_card()} | {:error, charge_error()}
  defp decode_scan(bus, {uid, sak, ndef}) do
    with {:ok, card} <- decode_card(ndef) do
      {:ok, {card, {bus, uid, sak}}}
    end
  end

  @spec charge_card(card(), locator(), pos_integer()) :: {:ok, term()} | {:error, charge_error()}
  defp charge_card({:sin, id}, _locator, amount) do
    ledger_transfer("sin:" <> id, amount)
  end

  defp charge_card({:cred, balance}, _locator, amount) when balance < amount do
    {:error, :insufficient_funds}
  end

  defp charge_card({:cred, balance}, locator, amount) do
    with {:ok, _new_balance} <- write_balance(locator, balance - amount) do
      case ledger_transfer(nil, amount) do
        {:ok, _result} = ok -> ok
        {:error, credit_error} -> restore_balance(locator, balance, credit_error)
      end
    end
  end

  # `BotClient.transfer/3` raises on transport errors and unexpected response
  # bodies; turn those into errors so a debited credstick still gets restored.
  @spec ledger_transfer(String.t() | nil, pos_integer()) :: {:ok, term()} | {:error, term()}
  defp ledger_transfer(sender, amount) do
    BotClient.transfer(sender, @receiver, amount)
  rescue
    exception -> {:error, exception}
  end

  @spec restore_balance(locator(), non_neg_integer(), term()) :: {:error, charge_error()}
  defp restore_balance({bus, uid, sak} = locator, old_balance, credit_error) do
    case write_balance(locator, old_balance) do
      {:ok, ^old_balance} ->
        {:error, credit_error}

      {:error, compensation_error} ->
        {:error,
         {:reconciliation_required,
          %{
            bus: bus,
            uid: uid,
            sak: sak,
            expected_balance: old_balance,
            credit_error: credit_error,
            compensation_error: compensation_error
          }}}
    end
  end

  @spec write_balance(locator(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp write_balance({bus, uid, sak}, balance) do
    message = NDEF.encode_records([NDEF.encode_text(Integer.to_string(balance))])

    case PN532Server.write_ndef(bus, uid, sak, message) do
      :ok -> {:ok, balance}
      {:error, _reason} = error -> error
    end
  end
end
