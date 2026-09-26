defmodule BarBanker.Shop.Inventory do
  @moduledoc """
  Static menu data from `priv/data/inventory.json`.

  The file maps slugs to items, `"<slug>": {"label": ..., "children": {...}}` for
  categories and `"<slug>": {"label": ..., "price": ...}` for purchasable items.
  Each level is decoded into an ordered list of `{slug, item}` so the menu keeps
  the order of the file, and an item is addressed by its list-of-slugs `path`.
  """

  def get_shop_items() do
    :code.priv_dir(:bar_banker)
    |> Path.join("data/inventory.json")
    |> File.read!()
    |> decode!()
  end

  def item(inventory, []), do: inventory

  def item(inventory, [slug | rest]) do
    case List.keyfind(inventory, slug, 0) do
      {^slug, item} when rest == [] -> item
      {^slug, %{"children" => children}} -> item(children, rest)
      _ -> nil
    end
  end

  def items(inventory, []), do: inventory

  def items(inventory, path) do
    case item(inventory, path) do
      %{"children" => children} -> children
      _ -> nil
    end
  end

  defp decode!(json) do
    {entries, nil, rest} =
      JSON.decode(json, nil,
        object_finish: fn acc, old_acc -> {{:ordered, Enum.reverse(acc)}, old_acc} end
      )

    "" = String.trim(rest)
    to_entries(entries)
  end

  defp to_entries({:ordered, entries}) do
    for {slug, {:ordered, fields}} <- entries do
      {slug, Map.new(fields, &to_field/1)}
    end
  end

  defp to_field({"children", children}), do: {"children", to_entries(children)}
  defp to_field(field), do: field
end
