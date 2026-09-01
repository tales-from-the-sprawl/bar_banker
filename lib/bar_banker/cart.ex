defmodule BarBanker.Cart do
  use Agent

  def start_link([]) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def add(path, item) do
    Agent.update(__MODULE__, fn map ->
      Map.update(map, path, {1, item}, fn {n, i} -> {n + 1, i} end)
    end)
  end

  def remove(path) do
    Agent.update(__MODULE__, fn map ->
      Map.get_and_update(map, path, fn
        {1, _} -> :pop
        {n, i} -> {{n, i}, {n - 1, i}}
      end)
      |> then(fn {_, s} -> s end)
    end)
  end

  def get() do
    Agent.get(__MODULE__, & &1)
    |> Map.values()
    |> Enum.map(fn {n, i} -> Map.put(i, "count", n) end)
  end

  def clear() do
    Agent.update(__MODULE__, fn _ -> %{} end)
    []
  end

  def total(cart) do
    cart
    |> Enum.map(&(&1["price"] * &1["count"]))
    |> Enum.sum()
  end
end
