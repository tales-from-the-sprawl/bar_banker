defmodule BarBanker.Shop do
  @moduledoc """
  Public boundary for the shop domain: the cart, the menu, member lookups,
  and charging a completed order.

  Everything outside this module — the LiveViews in particular — should
  call through here rather than reaching into `BarBanker.Shop.Cart`,
  `BarBanker.Shop.Inventory`, `BarBanker.Shop.Sin`, or `BarBanker.Shop.Client`
  directly.
  """

  alias BarBanker.Shop.Cart
  alias BarBanker.Shop.Client
  alias BarBanker.Shop.Inventory
  alias BarBanker.Shop.Sin

  @shop_handle "trinity_taskbar"

  ## Cart

  @doc "Subscribes the caller to cart broadcasts: `{:cart, :updated}` and `{:cart, :clear}`."
  def subscribe_cart() do
    Phoenix.PubSub.subscribe(BarBanker.PubSub, "cart")
  end

  def subscribe_order() do
    Phoenix.PubSub.subscribe(BarBanker.PubSub, "order")
  end

  @doc "The current cart, as a list of menu items with a `\"count\"` key."
  def get_cart() do
    Cart.get()
  end

  @doc "Adds one of `item` to the cart at `path` and notifies subscribers."
  def add_cart(path, item) do
    Cart.add(path, item)
    broadcast_cart({:cart, :updated})
  end

  @doc "Removes one of the item at `path` from the cart and notifies subscribers."
  def remove_cart(path) do
    Cart.remove(path)
    broadcast_cart({:cart, :updated})
  end

  @doc "Empties the cart, notifies subscribers, and returns the now-empty cart."
  def clear_cart() do
    cart = Cart.clear()
    broadcast_cart({:cart, :clear})
    cart
  end

  @doc "Total price of `cart`, as returned by `get_cart/0`."
  def cart_total(cart) do
    Cart.total(cart)
  end

  ## Menu

  @doc "The full menu tree, read from priv/data/inventory.json."
  def get_shop_items() do
    Inventory.get_shop_items()
  end

  @doc "The menu item at `path` in `inventory`."
  def item(inventory, path) do
    Inventory.item(inventory, path)
  end

  @doc "The child items under `path` in `inventory`."
  def items(inventory, path) do
    Inventory.items(inventory, path)
  end

  ## Members

  @doc "All known sin-code -> handle mappings, read from priv/data/sin.json."
  def get_sin_values() do
    Sin.get_sin_values()
  end

  @doc "Looks up the account handle for `sincode`, or `nil` if it isn't registered."
  def map_sincode(sincode) do
    Sin.map_sincode(sincode)
  end

  ## Checkout

  @doc "The ledger balance for `handle`."
  def balance(handle) do
    Client.balance(handle)
  end

  @doc """
  Charges `amount` from `sender`'s account to the shop's own account.

  Returns `{:ok, {message, amount}}` on success, `{:error, message}` if the
  ledger declined the transfer.
  """
  def checkout(sender, amount, opts \\ []) do
    broadcast_order({:order, :loading})
    res = Client.transfer(sender, @shop_handle, amount, opts)
    broadcast_order({:order, :ok})
    res
  end

  defp broadcast_cart(message) do
    Phoenix.PubSub.broadcast(BarBanker.PubSub, "cart", message)
  end

  defp broadcast_order(message) do
    Phoenix.PubSub.broadcast(BarBanker.PubSub, "order", message)
  end
end
