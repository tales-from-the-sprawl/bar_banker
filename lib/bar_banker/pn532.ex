defmodule BarBanker.PN532 do
  @moduledoc """
  Driver for the PN532 NFC/RFID reader IC over I2C (see NXP UM0701-02).

  Port of Adafruit's CircuitPython `adafruit_pn532` driver's I2C backend,
  built on `BarBanker.PN532.I2C` (bus transport) and `BarBanker.PN532.Frame` (protocol
  framing). Only the commands the reference driver implements are covered:
  firmware/SAM setup, ISO14443A passive target detection, and Mifare
  Classic/NTAG2xx block access.

  Every public function returns `{:ok, result} | {:error, reason}` for
  expected hardware/protocol failures (bus errors, timeouts, malformed
  frames, a card rejecting a Mifare command); only genuinely invalid
  arguments (wrong block-data size) raise, via function guards.
  """

  alias BarBanker.NDEF
  alias BarBanker.PN532.Frame
  alias BarBanker.PN532.I2C

  @enforce_keys [:i2c]
  defstruct [:i2c, :reset_gpio]

  @type t :: %__MODULE__{i2c: I2C.t(), reset_gpio: Circuits.GPIO.Handle.t() | nil}

  @type error ::
          :timeout
          | :bad_ack
          | :unexpected_response
          | {:power_down_rejected, status :: byte()}
          | Frame.reason()
          | :busy
          | :i2c_nak

  @command_get_firmware_version 0x02
  @command_sam_configuration 0x14
  @command_power_down 0x16
  @command_rf_configuration 0x32
  @command_in_list_passive_target 0x4A
  @command_in_data_exchange 0x40

  @mifare_cmd_auth_a 0x60
  @mifare_cmd_auth_b 0x61
  @mifare_cmd_read 0x30
  @mifare_cmd_write 0xA0
  @mifare_cmd_transfer 0xB0
  @mifare_cmd_decrement 0xC0
  @mifare_cmd_increment 0xC1
  @ntag_ultralight_cmd_write 0xA2

  @mifare_iso14443a 0x00
  @mifare_classic_sak_mask 0x08

  # RFConfiguration CfgItem 0x0A: the 11 CIU analog registers used for
  # 106 kbps Type A, in order CIU_RFCfg, GsNOn, CWGsP, ModGsP, DemodOwnRfOn,
  # RxThreshold, DemodOwnRfOff, GsNOff, ModWidth, MifNFC, TxBitPhase. These
  # are the UM0701-02 §7.3.1 defaults except for two receiver registers,
  # tuned so both a weakly-coupled Mifare Classic card and a strongly-coupled
  # NTAG read reliably with the same setting (see `configure_analog/1`):
  # * CIU_RFCfg `0x69` (default `0x59`): RxGain 43 dB instead of 38 dB.
  # * CIU_RxThreshold `0xC5` (default `0x85`): MinLevel 0xC instead of 0x8.
  @rf_cfg_item_analog_106_type_a 0x0A
  @analog_106_type_a <<0x69, 0xF4, 0x3F, 0x11, 0x4D, 0xC5, 0x61, 0x6F, 0x26, 0x62, 0x87>>

  # Attempts per Mifare Classic sector (or MAD) read before giving up; each
  # retry re-selects the card first, since an RF error drops its crypto state.
  @classic_read_attempts 3

  # PowerDown WakeUpEnable bitmask (UM0701-02 §7.2.11): only I2C (bit 7) is
  # wired, so only an I2C address match should wake the chip.
  @wakeup_enable_i2c 0x80
  # The chip only enters power-down ~1 ms after sending the PowerDown
  # response, and a wake edge before that is lost (the next command then
  # times out), measured on hardware as failing at 1 ms and working at 2 ms.
  @power_down_settle_ms 10

  @default_timeout_ms 1000
  @firmware_timeout_ms 500

  @ndef_start_page 4
  @ndef_max_pages 231

  @mad_key_a <<0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5>>
  @mad_sector_block 1
  @mad_ndef_aid <<0x03, 0xE1>>

  @ndef_key_a <<0xD3, 0xF7, 0xD3, 0xF7, 0xD3, 0xF7>>
  @classic_blocks_per_sector 4

  @type mad_error ::
          :mad_authentication_failed
          | :no_ndef_sectors
          | :target_changed
          | {:sector_authentication_failed, byte()}

  @type write_error :: {:sector_write_failed, byte()} | :write_failed | :message_too_large

  @doc """
  Opens the I2C bus, resets and wakes the PN532, puts it in normal (SAM)
  mode, and confirms it's alive by reading its firmware version.

  `opts`:
  * `:address` - the PN532's 7-bit I2C address, defaults to `0x24`.
  * `:reset_gpio` - an already-open `Circuits.GPIO` handle wired to the
    PN532's `RSTPDN` pin. When given, it's pulsed low then high around the
    wakeup, matching the reset sequence in the reference driver. Omit if
    no reset pin is wired.
  """
  @spec open(binary(), keyword()) :: {:ok, t()} | {:error, error()}
  def open(bus_name, opts \\ []) when is_binary(bus_name) do
    reset_gpio = Keyword.get(opts, :reset_gpio)
    i2c_opts = Keyword.take(opts, [:address])

    with {:ok, i2c} <- I2C.open(bus_name, i2c_opts),
         pn532 = %__MODULE__{i2c: i2c, reset_gpio: reset_gpio},
         :ok <- reset(pn532),
         :ok <- I2C.wakeup(i2c),
         :ok <- sam_configuration(pn532),
         :ok <- configure_analog(pn532),
         {:ok, _version} <- firmware_version(pn532) do
      {:ok, pn532}
    end
  end

  @doc "Releases the underlying I2C bus."
  @spec close(t()) :: :ok
  def close(pn532), do: I2C.close(pn532.i2c)

  @doc "Reads the chip's IC/firmware/revision/support byte tuple."
  @spec firmware_version(t()) :: {:ok, {byte(), byte(), byte(), byte()}} | {:error, error()}
  def firmware_version(pn532) do
    with {:ok, <<ic, version, revision, support>>} <-
           call_function(pn532, @command_get_firmware_version, <<>>, 4, @firmware_timeout_ms) do
      {:ok, {ic, version, revision, support}}
    end
  end

  @doc "Puts the PN532 in normal SAM mode (as opposed to virtual card/multicard mode)."
  @spec sam_configuration(t()) :: :ok | {:error, error()}
  def sam_configuration(pn532) do
    with {:ok, _response} <-
           call_function(pn532, @command_sam_configuration, <<0x01, 0x14, 0x01>>, 0) do
      :ok
    end
  end

  @doc """
  Applies this driver's tuned 106 kbps Type A analog settings (RFConfiguration
  item `0x0A`, UM0701-02 §7.3.1). Called by `open/2`.

  With the chip defaults (38 dB receiver gain), a card that couples weakly to
  its antenna is still detected and authenticated, but longer responses like
  16-byte block reads intermittently fail with an RF CRC error (status
  `0x02`), which on Mifare Classic also drops the card's authenticated state.
  Raising the gain to 43 dB alone fixes that but overdrives a
  strongly-coupled card (RF protocol errors, status `0x0B`); raising the
  receiver's MinLevel threshold alongside it suppresses that again, so one
  setting works for both.
  """
  @spec configure_analog(t()) :: :ok | {:error, error()}
  def configure_analog(pn532) do
    params = <<@rf_cfg_item_analog_106_type_a, @analog_106_type_a::binary>>

    with {:ok, _response} <- call_function(pn532, @command_rf_configuration, params, 0) do
      :ok
    end
  end

  @doc """
  Puts the PN532 into soft power-down (UM0701-02 §7.2.11): the RF field and
  oscillator stop, and only an I2C address match wakes it again.

  Call `wake_up/1` before issuing any other command. Returns only once the
  chip has actually entered power-down, so a following `wake_up/1` can't
  race it.
  """
  @spec power_down(t()) :: :ok | {:error, error()}
  def power_down(pn532) do
    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_power_down, <<@wakeup_enable_i2c, 0x00>>, 1) do
      if status == 0 do
        Process.sleep(@power_down_settle_ms)
        :ok
      else
        {:error, {:power_down_rejected, status}}
      end
    end
  end

  @doc """
  Wakes the PN532 from `power_down/1` and re-applies the SAM and analog
  settings from `open/2`, leaving it ready for commands again.
  """
  @spec wake_up(t()) :: :ok | {:error, error()}
  def wake_up(pn532) do
    with :ok <- I2C.wakeup(pn532.i2c),
         :ok <- sam_configuration(pn532) do
      configure_analog(pn532)
    end
  end

  @doc "Starts listening for a single passive ISO14443A target; call `get_passive_target/2` to retrieve it."
  @spec listen_for_passive_target(t(), byte()) :: :ok | {:error, error()}
  def listen_for_passive_target(pn532, card_baud \\ @mifare_iso14443a) do
    send_command(pn532, @command_in_list_passive_target, <<0x01, card_baud>>, @default_timeout_ms)
  end

  @doc "Retrieves the `{uid, sak}` of a target found after `listen_for_passive_target/2`."
  @spec get_passive_target(t(), non_neg_integer()) ::
          {:ok, {binary(), byte()}}
          | {:error, error() | :no_target_found | :too_many_cards | :uid_too_long}
  def get_passive_target(pn532, timeout_ms \\ @default_timeout_ms) do
    with {:ok, response} <-
           process_response(pn532, @command_in_list_passive_target, 64, timeout_ms) do
      parse_passive_target(response)
    end
  end

  @doc "Combines `listen_for_passive_target/2` and `get_passive_target/2` into a single call."
  @spec read_passive_target(t(), byte(), non_neg_integer()) ::
          {:ok, {binary(), byte()}}
          | {:error, error() | :no_target_found | :too_many_cards | :uid_too_long}
  def read_passive_target(
        pn532,
        card_baud \\ @mifare_iso14443a,
        timeout_ms \\ @default_timeout_ms
      ) do
    with :ok <- listen_for_passive_target(pn532, card_baud) do
      get_passive_target(pn532, timeout_ms)
    end
  end

  @doc "Authenticates a Mifare Classic block with a key, ahead of a read or write. `key_number` is `0` for key A, `1` for key B."
  @spec mifare_classic_authenticate_block(t(), binary(), byte(), byte(), binary()) ::
          {:ok, boolean()} | {:error, error()}
  def mifare_classic_authenticate_block(pn532, uid, block_number, key_number, key) do
    auth_command = if key_number == 0, do: @mifare_cmd_auth_a, else: @mifare_cmd_auth_b
    params = <<0x01, auth_command, block_number, key::binary, uid::binary>>

    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, status == 0}
    end
  end

  @doc "Reads a 16-byte Mifare Classic block. The block must already be authenticated."
  @spec mifare_classic_read_block(t(), byte()) :: {:ok, binary()} | {:error, error()}
  def mifare_classic_read_block(pn532, block_number) do
    params = <<0x01, @mifare_cmd_read, block_number>>

    case call_function(pn532, @command_in_data_exchange, params, 17) do
      {:ok, <<0, data::binary-size(16)>>} -> {:ok, data}
      {:ok, <<status, _rest::binary>>} -> {:error, {:mifare_status, status}}
      error -> error
    end
  end

  @doc "Writes a 16-byte Mifare Classic block. The block must already be authenticated."
  @spec mifare_classic_write_block(t(), byte(), binary()) :: {:ok, boolean()} | {:error, error()}
  def mifare_classic_write_block(pn532, block_number, data) when byte_size(data) == 16 do
    params = <<0x01, @mifare_cmd_write, block_number, data::binary>>

    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, status == 0}
    end
  end

  @doc "Subtracts `amount` from a Mifare Classic value block and commits it via TRANSFER."
  @spec mifare_classic_sub_value_block(t(), byte(), integer()) ::
          {:ok, boolean()} | {:error, error()}
  def mifare_classic_sub_value_block(pn532, block_number, amount) do
    value_op(pn532, @mifare_cmd_decrement, block_number, amount)
  end

  @doc "Adds `amount` to a Mifare Classic value block and commits it via TRANSFER."
  @spec mifare_classic_add_value_block(t(), byte(), integer()) ::
          {:ok, boolean()} | {:error, error()}
  def mifare_classic_add_value_block(pn532, block_number, amount) do
    value_op(pn532, @mifare_cmd_increment, block_number, amount)
  end

  @doc "Reads and validates a Mifare Classic value block, returning its signed integer value."
  @spec mifare_classic_get_value_block(t(), byte()) ::
          {:ok, integer()} | {:error, error() | :invalid_value_block}
  def mifare_classic_get_value_block(pn532, block_number) do
    with {:ok, block} <- mifare_classic_read_block(pn532, block_number) do
      parse_value_block(block)
    end
  end

  @doc "Formats a Mifare Classic block as a value block holding `initial_value`."
  @spec mifare_classic_fmt_value_block(t(), byte(), integer(), byte()) ::
          {:ok, boolean()} | {:error, error()}
  def mifare_classic_fmt_value_block(pn532, block_number, initial_value, address_block \\ 0) do
    value_bytes = <<initial_value::little-signed-32>>
    address_check = Bitwise.bxor(address_block, 0xFF)

    data =
      value_bytes <>
        invert(value_bytes) <>
        value_bytes <> <<address_block, address_check, address_block, address_check>>

    mifare_classic_write_block(pn532, block_number, data)
  end

  @doc "Reads a 4-byte NTAG2xx page."
  @spec ntag2xx_read_block(t(), byte()) :: {:ok, binary()} | {:error, error()}
  def ntag2xx_read_block(pn532, block_number) do
    with {:ok, <<page::binary-size(4), _rest::binary>>} <-
           mifare_classic_read_block(pn532, block_number) do
      {:ok, page}
    end
  end

  @doc "Writes a 4-byte NTAG2xx page."
  @spec ntag2xx_write_block(t(), byte(), binary()) :: {:ok, boolean()} | {:error, error()}
  def ntag2xx_write_block(pn532, block_number, data) when byte_size(data) == 4 do
    params = <<0x01, @ntag_ultralight_cmd_write, block_number, data::binary>>

    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, status == 0}
    end
  end

  @doc """
  Reads the NDEF message off a detected tag, dispatching on its SAK (as
  returned by `get_passive_target/2`): tags whose SAK marks them Mifare
  Classic-compliant are read via `mifare_classic_read_ndef/2` (MAD lookup
  plus per-sector authentication); everything else is read via
  `ntag2xx_read_ndef/1` (unauthenticated NTAG21x page reads).
  """
  @spec read_ndef(t(), binary(), byte()) ::
          {:ok, binary()} | {:error, error() | NDEF.reason() | mad_error()}
  def read_ndef(pn532, uid, sak) do
    if mifare_classic?(sak) do
      mifare_classic_read_ndef(pn532, uid)
    else
      ntag2xx_read_ndef(pn532)
    end
  end

  @doc """
  Reads the raw NDEF message from an NTAG21x tag's user memory, starting at
  page 4 and unwrapping the TLV block structure. Reads stop as soon as the
  TLVs read so far end in the Terminator TLV, or otherwise once the tag
  reports an out-of-bounds block (end of its memory).
  """
  @spec ntag2xx_read_ndef(t()) :: {:ok, binary()} | {:error, error() | NDEF.reason()}
  def ntag2xx_read_ndef(pn532) do
    with {:ok, data} <- read_pages(pn532, @ndef_start_page, @ndef_max_pages, <<>>) do
      NDEF.decode(data)
    end
  end

  @doc """
  Reads the raw NDEF message from a Mifare Classic 1K tag. Authenticates
  sector 0 with the well-known MAD key A (`A0A1A2A3A4A5`) to read the MAD
  (Mifare Application Directory) and find which sectors it marks with the
  NDEF application id (`03E1`), then authenticates and reads each of those
  sectors' 3 data blocks (skipping the trailer block that holds keys/access
  bits) with the well-known NDEF key A (`D3F7D3F7D3F7`), concatenating them
  in ascending sector order and unwrapping the TLV block structure. Reading
  stops at the first sector that completes the NDEF message, rather than
  reading every sector the MAD lists.

  A failed MAD or sector read (e.g. an RF CRC error) is retried a few times,
  re-selecting the card first to restore its authenticated state.

  Only the single-MAD, 16-sector Mifare Classic 1K layout is supported.
  """
  @spec mifare_classic_read_ndef(t(), binary()) ::
          {:ok, binary()} | {:error, error() | NDEF.reason() | mad_error()}
  def mifare_classic_read_ndef(pn532, uid) do
    with {:ok, sectors} <- read_mad_ndef_sectors(pn532, uid) do
      read_ndef_sectors(pn532, uid, Enum.sort(sectors), <<>>)
    end
  end

  @doc """
  Writes an NDEF message (as accepted by `NDEF.encode_records/1`/returned by
  `NDEF.decode/1`) to a detected tag, dispatching on its SAK exactly like
  `read_ndef/3`.

  The tag is re-selected first (failing with `:target_changed` if a
  different tag answers), since whatever ran since it was detected may have
  left it unselected: `ntag2xx_read_ndef/1` on a tag with no Terminator TLV
  reads until the tag NAKs an out-of-bounds page, which drops an NTAG back
  to IDLE so every later write is rejected, and `power_down/1` turns the RF
  field off entirely.

  A failed write may leave the tag in a partially-written state; retry the
  whole write on failure rather than assuming partial success is safe to
  build on.
  """
  @spec write_ndef(t(), binary(), byte(), binary()) ::
          :ok | {:error, error() | mad_error() | write_error()}
  def write_ndef(pn532, uid, sak, message) do
    with :ok <- reselect(pn532, uid) do
      if mifare_classic?(sak) do
        mifare_classic_write_ndef(pn532, uid, message)
      else
        ntag2xx_write_ndef(pn532, message)
      end
    end
  end

  @doc """
  Writes an NDEF message to an NTAG21x tag's user memory starting at page 4,
  padding the TLV-wrapped message to a 4-byte page boundary with trailing
  `0x00` bytes after the terminator TLV. Writes stop and report the error as
  soon as the tag rejects a page (e.g. because the message ran past the end
  of its memory).
  """
  @spec ntag2xx_write_ndef(t(), binary()) :: :ok | {:error, error() | write_error()}
  def ntag2xx_write_ndef(pn532, message) do
    message
    |> NDEF.encode()
    |> chunk_padded(4)
    |> write_pages(pn532, @ndef_start_page)
  end

  @doc """
  Writes an NDEF message to a Mifare Classic 1K tag, via the same MAD-tagged
  NDEF sectors `mifare_classic_read_ndef/2` reads from. Fails with
  `:message_too_large` without writing anything if the message doesn't fit
  in the tag's NDEF sectors' combined capacity (3 data blocks of 16 bytes
  each per sector).

  Only the single-MAD, 16-sector Mifare Classic 1K layout is supported.
  """
  @spec mifare_classic_write_ndef(t(), binary(), binary()) ::
          :ok | {:error, error() | mad_error() | write_error()}
  def mifare_classic_write_ndef(pn532, uid, message) do
    chunks = message |> NDEF.encode() |> chunk_padded(16)

    with {:ok, sectors} <- read_mad_ndef_sectors(pn532, uid) do
      capacity = length(sectors) * (@classic_blocks_per_sector - 1)

      if length(chunks) > capacity do
        {:error, :message_too_large}
      else
        write_ndef_sectors(pn532, uid, Enum.sort(sectors), chunks)
      end
    end
  end

  @doc """
  Splits `data` into `chunk_size`-byte chunks, zero-padding it to a multiple
  of `chunk_size` first if needed. Used to lay a TLV-wrapped NDEF message out
  across a tag's fixed-size pages/blocks.
  """
  @spec chunk_padded(binary(), pos_integer()) :: [binary()]
  def chunk_padded(data, chunk_size) do
    padding_size = rem(chunk_size - rem(byte_size(data), chunk_size), chunk_size)
    padded = data <> :binary.copy(<<0>>, padding_size)

    for <<chunk::binary-size(^chunk_size) <- padded>>, do: chunk
  end

  @spec mifare_classic?(byte()) :: boolean()
  defp mifare_classic?(sak), do: Bitwise.band(sak, @mifare_classic_sak_mask) != 0

  @spec read_mad_ndef_sectors(t(), binary()) ::
          {:ok, [byte()]} | {:error, error() | :mad_authentication_failed}
  defp read_mad_ndef_sectors(pn532, uid) do
    with_reselect_retry(pn532, uid, @classic_read_attempts, fn -> read_mad(pn532, uid) end)
  end

  @spec read_mad(t(), binary()) ::
          {:ok, [byte()]} | {:error, error() | :mad_authentication_failed}
  defp read_mad(pn532, uid) do
    with {:ok, true} <-
           mifare_classic_authenticate_block(pn532, uid, @mad_sector_block, 0, @mad_key_a),
         {:ok, block1} <- mifare_classic_read_block(pn532, @mad_sector_block),
         {:ok, block2} <- mifare_classic_read_block(pn532, @mad_sector_block + 1) do
      {:ok, parse_mad(block1, block2)}
    else
      {:ok, false} -> {:error, :mad_authentication_failed}
      error -> error
    end
  end

  @spec parse_mad(binary(), binary()) :: [byte()]
  defp parse_mad(<<_crc, _info, sectors_1_to_7::binary-size(14)>>, sectors_8_to_15) do
    (sectors_1_to_7 <> sectors_8_to_15)
    |> aid_pairs()
    |> Enum.with_index(1)
    |> Enum.filter(fn {aid, _sector} -> aid == @mad_ndef_aid end)
    |> Enum.map(fn {_aid, sector} -> sector end)
  end

  @spec aid_pairs(binary()) :: [binary()]
  defp aid_pairs(<<aid::binary-size(2), rest::binary>>), do: [aid | aid_pairs(rest)]
  defp aid_pairs(<<>>), do: []

  @spec read_ndef_sectors(t(), binary(), [byte()], binary()) ::
          {:ok, binary()} | {:error, error() | NDEF.reason() | mad_error()}
  defp read_ndef_sectors(_pn532, _uid, [], <<>>), do: {:error, :no_ndef_sectors}
  defp read_ndef_sectors(_pn532, _uid, [], acc), do: NDEF.decode(acc)

  defp read_ndef_sectors(pn532, uid, [sector | rest], acc) do
    read = fn -> read_ndef_sector(pn532, uid, sector) end

    with {:ok, data} <- with_reselect_retry(pn532, uid, @classic_read_attempts, read) do
      acc = acc <> data

      case NDEF.decode(acc) do
        {:ok, message} -> {:ok, message}
        {:error, _incomplete} -> read_ndef_sectors(pn532, uid, rest, acc)
      end
    end
  end

  # Runs `fun`, re-selecting the card and retrying on failure: after an RF
  # error mid-transaction a Mifare Classic card is no longer authenticated
  # (every later command fails), so the retry needs a fresh selection.
  @spec with_reselect_retry(t(), binary(), pos_integer(), (-> result)) ::
          result | {:error, error() | :no_target_found | :target_changed}
        when result: {:ok, term()} | {:error, term()}
  defp with_reselect_retry(pn532, uid, attempts, fun) do
    case fun.() do
      {:error, _reason} when attempts > 1 ->
        with :ok <- reselect(pn532, uid) do
          with_reselect_retry(pn532, uid, attempts - 1, fun)
        end

      result ->
        result
    end
  end

  @spec reselect(t(), binary()) :: :ok | {:error, term()}
  defp reselect(pn532, uid) do
    case read_passive_target(pn532) do
      {:ok, {^uid, _sak}} -> :ok
      {:ok, {_other_uid, _sak}} -> {:error, :target_changed}
      error -> error
    end
  end

  @spec read_ndef_sector(t(), binary(), byte()) ::
          {:ok, binary()} | {:error, error() | {:sector_authentication_failed, byte()}}
  defp read_ndef_sector(pn532, uid, sector) do
    first_block = sector * @classic_blocks_per_sector
    trailer_block = first_block + @classic_blocks_per_sector - 1

    case mifare_classic_authenticate_block(pn532, uid, first_block, 0, @ndef_key_a) do
      {:ok, true} -> read_sector_data_blocks(pn532, first_block, trailer_block, <<>>)
      {:ok, false} -> {:error, {:sector_authentication_failed, sector}}
      error -> error
    end
  end

  @spec read_sector_data_blocks(t(), byte(), byte(), binary()) ::
          {:ok, binary()} | {:error, error()}
  defp read_sector_data_blocks(_pn532, trailer_block, trailer_block, acc), do: {:ok, acc}

  defp read_sector_data_blocks(pn532, block, trailer_block, acc) do
    with {:ok, data} <- mifare_classic_read_block(pn532, block) do
      read_sector_data_blocks(pn532, block + 1, trailer_block, acc <> data)
    end
  end

  @spec read_pages(t(), byte(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, error()}
  defp read_pages(_pn532, _page, 0, acc), do: {:ok, acc}

  defp read_pages(pn532, page, remaining, acc) do
    case ntag2xx_read_block(pn532, page) do
      {:ok, data} ->
        acc = acc <> data

        if NDEF.tlv_terminated?(acc),
          do: {:ok, acc},
          else: read_pages(pn532, page + 1, remaining - 1, acc)

      {:error, {:mifare_status, _status}} ->
        {:ok, acc}

      {:error, _reason} = error ->
        error
    end
  end

  @spec write_pages([binary()], t(), byte()) :: :ok | {:error, error() | write_error()}
  defp write_pages([], _pn532, _page), do: :ok

  defp write_pages([chunk | rest], pn532, page) do
    case ntag2xx_write_block(pn532, page, chunk) do
      {:ok, true} -> write_pages(rest, pn532, page + 1)
      {:ok, false} -> {:error, :write_failed}
      error -> error
    end
  end

  @spec write_ndef_sectors(t(), binary(), [byte()], [binary()]) ::
          :ok | {:error, error() | write_error()}
  defp write_ndef_sectors(pn532, uid, sectors, chunks) do
    chunks
    |> Enum.chunk_every(@classic_blocks_per_sector - 1)
    |> Enum.zip(sectors)
    |> Enum.reduce_while(:ok, fn {sector_chunks, sector}, :ok ->
      case write_ndef_sector(pn532, uid, sector, sector_chunks) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @spec write_ndef_sector(t(), binary(), byte(), [binary()]) ::
          :ok | {:error, error() | {:sector_authentication_failed, byte()} | write_error()}
  defp write_ndef_sector(pn532, uid, sector, chunks) do
    first_block = sector * @classic_blocks_per_sector

    case mifare_classic_authenticate_block(pn532, uid, first_block, 0, @ndef_key_a) do
      {:ok, true} -> write_sector_data_blocks(pn532, first_block, chunks, sector)
      {:ok, false} -> {:error, {:sector_authentication_failed, sector}}
      error -> error
    end
  end

  @spec write_sector_data_blocks(t(), byte(), [binary()], byte()) ::
          :ok | {:error, error() | write_error()}
  defp write_sector_data_blocks(_pn532, _block, [], _sector), do: :ok

  defp write_sector_data_blocks(pn532, block, [chunk | rest], sector) do
    case mifare_classic_write_block(pn532, block, chunk) do
      {:ok, true} -> write_sector_data_blocks(pn532, block + 1, rest, sector)
      {:ok, false} -> {:error, {:sector_write_failed, sector}}
      error -> error
    end
  end

  @spec reset(t()) :: :ok
  defp reset(%__MODULE__{reset_gpio: nil}), do: :ok

  defp reset(%__MODULE__{reset_gpio: gpio}) do
    :ok = Circuits.GPIO.write(gpio, 0)
    Process.sleep(100)
    :ok = Circuits.GPIO.write(gpio, 1)
    Process.sleep(100)
    :ok
  end

  @spec value_op(t(), byte(), byte(), integer()) :: {:ok, boolean()} | {:error, error()}
  defp value_op(pn532, op, block_number, amount) do
    params = <<0x01, op, block_number, amount::little-signed-32>>

    case call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, <<0, _rest::binary>>} -> transfer(pn532, block_number)
      {:ok, <<_status, _rest::binary>>} -> {:ok, false}
      error -> error
    end
  end

  @spec transfer(t(), byte()) :: {:ok, boolean()} | {:error, error()}
  defp transfer(pn532, block_number) do
    params = <<0x01, @mifare_cmd_transfer, block_number>>

    with {:ok, <<status, _rest::binary>>} <-
           call_function(pn532, @command_in_data_exchange, params, 1) do
      {:ok, status == 0}
    end
  end

  @spec parse_passive_target(binary()) ::
          {:ok, {binary(), byte()}} | {:error, :no_target_found | :too_many_cards | :uid_too_long}
  defp parse_passive_target(<<1, _tg, _sens_res::binary-size(2), sak, uid_len, rest::binary>>)
       when uid_len <= 7 do
    <<uid::binary-size(^uid_len), _rest::binary>> = rest
    {:ok, {uid, sak}}
  end

  defp parse_passive_target(<<1, _rest::binary>>), do: {:error, :uid_too_long}
  defp parse_passive_target(<<0, _rest::binary>>), do: {:error, :no_target_found}
  defp parse_passive_target(_response), do: {:error, :too_many_cards}

  @spec parse_value_block(binary()) :: {:ok, integer()} | {:error, :invalid_value_block}
  defp parse_value_block(
         <<value_bytes::binary-size(4), inv_bytes::binary-size(4), dup_bytes::binary-size(4),
           _address::binary-size(4)>>
       ) do
    if dup_bytes == value_bytes and inv_bytes == invert(value_bytes) do
      <<value::little-signed-32>> = value_bytes
      {:ok, value}
    else
      {:error, :invalid_value_block}
    end
  end

  @spec invert(binary()) :: binary()
  defp invert(bytes), do: for(<<byte <- bytes>>, into: <<>>, do: <<Bitwise.bxor(byte, 0xFF)>>)

  @spec send_command(t(), byte(), binary(), non_neg_integer()) :: :ok | {:error, error()}
  defp send_command(pn532, command, params, timeout_ms) do
    frame = Frame.encode(command, params)
    ack_size = byte_size(Frame.ack_frame())

    with :ok <- I2C.write_data(pn532.i2c, frame),
         :ok <- I2C.wait_ready(pn532.i2c, timeout_ms),
         {:ok, ack} <- I2C.read_data(pn532.i2c, ack_size) do
      if Frame.ack?(ack), do: :ok, else: {:error, :bad_ack}
    end
  end

  @spec process_response(t(), byte(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, error()}
  defp process_response(pn532, command, response_length, timeout_ms) do
    with :ok <- I2C.wait_ready(pn532.i2c, timeout_ms),
         {:ok, raw} <- I2C.read_data(pn532.i2c, response_length + 9),
         {:ok, payload} <- Frame.decode(raw) do
      if Frame.response_to?(payload, command) do
        {:ok, Frame.response_data(payload)}
      else
        {:error, :unexpected_response}
      end
    end
  end

  @spec call_function(t(), byte(), binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, error()}
  defp call_function(pn532, command, params, response_length, timeout_ms \\ @default_timeout_ms) do
    with :ok <- send_command(pn532, command, params, timeout_ms) do
      process_response(pn532, command, response_length, timeout_ms)
    end
  end
end
