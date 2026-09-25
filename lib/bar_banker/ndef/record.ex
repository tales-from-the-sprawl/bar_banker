defmodule BarBanker.NDEF.Record do
  @moduledoc """
  A single decoded NDEF record (see the NFC Forum "NDEF" technical
  specification §2.3): a type/id/payload triple tagged with a Type Name
  Format (TNF) that says how to interpret `type` (e.g. `:well_known` types
  `"T"`/`"U"` are the NFC Forum Text/URI record types).
  """

  @type tnf ::
          :empty
          | :well_known
          | :mime_media
          | :absolute_uri
          | :external
          | :unknown
          | :unchanged
          | :reserved

  @type t :: %__MODULE__{tnf: tnf(), type: binary(), id: binary(), payload: binary()}

  @enforce_keys [:tnf, :type, :id, :payload]
  defstruct [:tnf, :type, :id, :payload]
end
