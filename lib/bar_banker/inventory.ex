defmodule BarBanker.Inventory do
  def get_shop_items() do
    :code.priv_dir(:bar_banker)
    |> Path.join("data/inventory.json")
    |> File.read!()
    |> JSON.decode!()
  end

  def find(menu, category) do
    menu
    |> Enum.find(&(&1["code"] == category))
    |> then(fn %{"children" => c} -> c end)
  end

  def find(menu, category, item) do
    menu
    |> find(category)
    |> Enum.find(&(&1["code"] == item))
  end

  def get_shop_items_debug() do
    [
      %{key: "Q", code: "KeyQ", label: "Noodles", price: 100},
      %{key: "W", code: "KeyW", label: "Food", price: 150},
      %{key: "E", code: "KeyE", label: "Drink", price: 50}
    ]
  end
end
