defmodule BarBanker.Inventory do
  def get_shop_items() do
    :code.priv_dir(:bar_banker)
    |> Path.join("data/inventory.json")
    |> File.read!()
    |> JSON.decode!()
  end

  def item(inventory, []), do: inventory
  def item(inventory, path), do: get_in(inventory, Enum.intersperse(path, "children"))

  def items(inventory, []), do: inventory
  def items(inventory, path), do: get_in(item(inventory, path), ["children"])
end
