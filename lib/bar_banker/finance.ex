defmodule BarBanker.Finance do
  @moduledoc """
  Transfers funds between the two cards scanned on the kiosk's fixed NFC readers.

  A **sincard** carries a `"sin:xxxx"` handle; its balance lives remotely and is
  moved with `BarBanker.BotClient.transfer/3,4`. A **credstick** carries its balance as a
  plain integer string directly in its NDEF text record, so moving money to/from
  one means rewriting that record via `BarBanker.PN532.Server.write_ndef/4`.

  Since a transfer between anything but two sincards needs two separate operations
  (an HTTP call and/or one or two card writes) that can't be done atomically, every
  such transfer always runs its debit step before its credit step, and
  automatically compensates (refunds/rewrites) the debit step if the credit step
  fails, so a partial failure never duplicates money - at worst it's destroyed and
  reported as needing manual reconciliation.
  """

  alias BarBanker.BotClient
  alias BarBanker.NDEF
  alias BarBanker.PN532.Server, as: PN532Server

  @sender_bus "spidev0.1"
  @receiver_bus "spidev0.0"

  @type card :: {:sin, String.t()} | {:cred, non_neg_integer()}
  @type locator :: {bus :: String.t(), uid :: binary(), sak :: byte()}

  @type step ::
          {:bot_transfer, sender :: String.t() | nil, receiver :: String.t() | nil,
           amount :: integer()}
          | {:write_balance, side :: :sender | :receiver, new_balance :: non_neg_integer(),
             old_balance :: non_neg_integer()}

  @type reconciliation_error ::
          {:reconciliation_required,
           %{
             sender_handle: String.t(),
             amount: integer(),
             debit_error: term(),
             compensation_error: term()
           }}
          | {:reconciliation_required,
             %{
               bus: String.t(),
               uid: binary(),
               sak: byte(),
               expected_balance: non_neg_integer(),
               debit_error: term(),
               compensation_error: term()
             }}

  @type transfer_error ::
          :invalid_amount
          | :insufficient_funds
          | :card_not_recognized
          | :no_text_record
          | reconciliation_error()
          | term()

  @doc "Classifies a decoded NDEF text record as a sincard handle or a credstick balance."
  @spec parse_card({String.t(), String.t()}) :: {:ok, card()} | {:error, :card_not_recognized}
  def parse_card({_language, "sin:" <> id}) do
    {:ok, {:sin, id}}
  end

  def parse_card({_language, content}) do
    case Integer.parse(content) do
      {value, ""} -> {:ok, {:cred, value}}
      _other -> {:error, :card_not_recognized}
    end
  end

  @doc """
  Decodes a scanned tag's NDEF message (as returned by `BarBanker.PN532.Server.scan/1`)
  into a `card/0`, passing through a scan-level NDEF read error unchanged.
  """
  @spec decode_card({:ok, binary()} | {:error, term()}) ::
          {:ok, card()} | {:error, transfer_error()}
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
  Plans the ordered steps to move `amount` from `sender` to `receiver`, or an error
  if the transfer can't proceed (an invalid amount, or a credstick sender without
  enough balance). Pure - performs no I/O.
  """
  @spec plan_transfer(card(), card(), integer()) :: {:ok, [step()]} | {:error, transfer_error()}
  def plan_transfer(_sender, _receiver, amount) when amount <= 0, do: {:error, :invalid_amount}

  def plan_transfer({:sin, sender_id}, {:sin, receiver_id}, amount) do
    {:ok, [{:bot_transfer, "sin:" <> sender_id, "sin:" <> receiver_id, amount}]}
  end

  def plan_transfer({:sin, sender_id}, {:cred, receiver_balance}, amount) do
    {:ok,
     [
       {:bot_transfer, "sin:" <> sender_id, nil, amount},
       {:write_balance, :receiver, receiver_balance + amount, receiver_balance}
     ]}
  end

  def plan_transfer({:cred, sender_balance}, {:sin, receiver_id}, amount)
      when sender_balance >= amount do
    {:ok,
     [
       {:write_balance, :sender, sender_balance - amount, sender_balance},
       {:bot_transfer, nil, "sin:" <> receiver_id, amount}
     ]}
  end

  def plan_transfer({:cred, _sender_balance}, {:sin, _receiver_id}, _amount),
    do: {:error, :insufficient_funds}

  def plan_transfer({:cred, sender_balance}, {:cred, receiver_balance}, amount)
      when sender_balance >= amount do
    {:ok,
     [
       {:write_balance, :sender, sender_balance - amount, sender_balance},
       {:write_balance, :receiver, receiver_balance + amount, receiver_balance}
     ]}
  end

  def plan_transfer({:cred, _sender_balance}, {:cred, _receiver_balance}, _amount),
    do: {:error, :insufficient_funds}

  @doc """
  Transfers `amount` from the card on `#{@sender_bus}` to the card on
  `#{@receiver_bus}` - the kiosk's two NFC readers have fixed sender/receiver
  roles.

  Note: `BarBanker.BotClient.transfer/3,4` has no catch-all clause on its response body,
  so an unexpected response shape raises instead of returning `{:error, _}`; if
  that happens on the credit step after the debit step already succeeded, this
  function crashes rather than running its compensation.
  """
  @spec transfer(pos_integer()) :: {:ok, term()} | {:error, transfer_error()}
  def transfer(amount) do
    with {:ok, {sender_uid, sender_sak, sender_ndef}} <- PN532Server.scan(@sender_bus),
         {:ok, {receiver_uid, receiver_sak, receiver_ndef}} <- PN532Server.scan(@receiver_bus),
         {:ok, sender_card} <- decode_card(sender_ndef),
         {:ok, receiver_card} <- decode_card(receiver_ndef),
         {:ok, steps} <- plan_transfer(sender_card, receiver_card, amount) do
      execute_steps(steps, %{
        sender: {@sender_bus, sender_uid, sender_sak},
        receiver: {@receiver_bus, receiver_uid, receiver_sak}
      })
    end
  end

  @spec execute_steps([step()], %{sender: locator(), receiver: locator()}) ::
          {:ok, term()} | {:error, transfer_error()}
  defp execute_steps([step], parties), do: run_step(step, parties)

  defp execute_steps([debit_step, credit_step], parties) do
    case run_step(debit_step, parties) do
      {:ok, _result} ->
        case run_step(credit_step, parties) do
          {:ok, _result} = ok -> ok
          {:error, credit_error} -> compensate(debit_step, credit_error, parties)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec run_step(step(), %{sender: locator(), receiver: locator()}) ::
          {:ok, term()} | {:error, term()}
  defp run_step({:bot_transfer, sender, receiver, amount}, _parties) do
    BotClient.transfer(sender, receiver, amount)
  end

  defp run_step({:write_balance, side, new_balance, _old_balance}, parties) do
    write_balance(Map.fetch!(parties, side), new_balance)
  end

  @spec compensate(step(), term(), %{sender: locator(), receiver: locator()}) ::
          {:error, transfer_error()}
  defp compensate({:bot_transfer, sender, receiver, amount}, credit_error, _parties) do
    case BotClient.transfer(receiver, sender, amount) do
      {:ok, _result} ->
        {:error, credit_error}

      {:error, compensation_error} ->
        {:error,
         {:reconciliation_required,
          %{
            sender_handle: sender || receiver,
            amount: amount,
            debit_error: credit_error,
            compensation_error: compensation_error
          }}}
    end
  end

  defp compensate({:write_balance, side, _new_balance, old_balance}, credit_error, parties) do
    {bus, uid, sak} = locator = Map.fetch!(parties, side)

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
            debit_error: credit_error,
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
