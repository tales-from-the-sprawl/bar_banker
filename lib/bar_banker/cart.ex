defmodule BarBanker.Cart do
  use GenServer

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def add(item) do
    GenServer.call(__MODULE__, {:add, item})
  end

  def remove(item) do
    GenServer.call(__MODULE__, {:remove, item})
  end

  def get() do
    GenServer.call(__MODULE__, :get)
  end

  def total() do
    GenServer.call(__MODULE__, :total)
  end

  def clear() do
    GenServer.call(__MODULE__, :clear)
  end

  @impl GenServer
  def init(_init_arg) do
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:add, %{"code" => code} = item}, _from, cart) do
    item = Map.put(item, "count", 1)
    cart = Map.update(cart, code, item, &inc_count/1)
    {:reply, :ok, cart}
  end

  @impl GenServer
  def handle_call({:remove, %{"code" => code}}, _from, cart) do
    cart =
      Map.update(cart, code, nil, &dec_count/1)
      |> Map.filter(fn {_, val} -> val != nil end)

    {:reply, :ok, cart}
  end

  @impl GenServer
  def handle_call(:get, _from, cart) do
    data = cart |> Map.values()
    {:reply, data, cart}
  end

  @impl GenServer
  def handle_call(:total, _from, cart) do
    data =
      cart
      |> Map.values()
      |> Enum.map(&(&1["price"] * &1["count"]))
      |> Enum.sum()

    {:reply, data, cart}
  end

  @impl GenServer
  def handle_call(:clear, _from, _cart) do
    {:reply, :ok, %{}}
  end

  defp inc_count(%{"count" => count} = item), do: %{item | "count" => count + 1}

  defp dec_count(%{"count" => 1}), do: nil
  defp dec_count(%{"count" => count} = item), do: %{item | "count" => count - 1}
end
