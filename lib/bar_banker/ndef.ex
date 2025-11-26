defmodule NDEF do
  @doc """
  Parses a single short NDEF record.
  Returns %{tnf:, type:, payload:, language:, text:}
  """
  @spec parse_short_record(binary()) :: %{tnf: integer(), type: binary(), payload: binary()}
  def parse_short_record(<<
        # 1 byte
        flags,
        # 1 byte
        type_len,
        # 1 byte (SR=1)
        payload_len,
        type::binary-size(type_len),
        payload::binary-size(payload_len),
        # leftover bytes
        rest::binary
      >>) do
    {_, _, _, 1, _, tnf} = parse_flags(<<flags>>)

    # For a Text Record ("T")
    result =
      case {tnf, type} do
        {0x01, "T"} ->
          parse_text_payload(payload)

        _ ->
          %{tnf: tnf, type: type, payload: payload}
      end

    {result, rest}
  end

  # Parse NDEF Well-known Text Record payload
  defp parse_text_payload(<<lang_len, rest::binary>>) do
    <<lang::binary-size(lang_len), text::binary>> = rest

    %{
      tnf: 0x01,
      type: "T",
      language: lang,
      text: text,
      payload: rest
    }
  end

  @doc """
  Field	Size	  Description
  MB	  1 bit	  Message Begin
  ME	  1 bit	  Message End
  CF	  1 bit	  Chunk Flag
  SR	  1 bit	  Short Record
  IL	  1 bit	  ID Length present
  TNF	  3 bits	Type Name Format
  """
  defp parse_flags(<<mb::1, me::1, cf::1, sr::1, il::1, tnf::3>>) do
    {mb, me, cf, sr, il, tnf}
  end
end
