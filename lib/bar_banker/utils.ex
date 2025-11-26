defmodule BarBanker.Utils do
  @doc """
  Dedupes a list of key press and release events.

  ## Examples

      iex> dedupe_events([pressed: :k001, released: :k001])
      []

      iex> dedupe_events([released: :k001, pressed: :k001])
      []

      iex> dedupe_events([pressed: :k001, released: :k001, pressed: :k001])
      [pressed: :k001]

      iex> dedupe_events([released: :k001, pressed: :k001, released: :k001])
      [released: :k001]

      iex> dedupe_events([pressed: :k001, pressed: :k002, released: :k001])
      [pressed: :k002]

      iex> dedupe_events([pressed: :k001, pressed: :k002, released: :k002, released: :k001])
      []

      iex> dedupe_events([released: :k002, released: :k001, pressed: :k002, pressed: :k001])
      []
  """
  def dedupe_events(events) do
    events
    |> Enum.reduce([], fn {type, key}, acc ->
      opposite = opposite(type)

      case Keyword.get(acc, key) do
        nil -> [{key, type} | acc]
        ^opposite -> Keyword.delete(acc, key)
      end
    end)
    |> Enum.reduce([], fn {x, y}, acc -> [{y, x} | acc] end)
  end

  defp opposite(:pressed), do: :released
  defp opposite(:released), do: :pressed
end
