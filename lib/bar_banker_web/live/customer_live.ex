defmodule BarBankerWeb.CustomerLive do
  use BarBankerWeb, :live_view
  alias BarBanker.Shop
  import BarBanker.Utils, only: [fmt_money: 1]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%= if @cart == [] do %>
        <div class="grid place-content-center">
          <img
            src="/images/Trinity_Tall.png"
            alt="Trinity Taskbar"
            class="w-[384px] border-none block"
          />
        </div>
      <% else %>
        <div class="px-3 py-4">
          <img
            src="/images/Trinity_Rect.png"
            alt="Trinity Taskbar"
            class="h-24 border-none block"
          />
          <div class="border-2 mb-2 px-1">
            <span>Order total: </span>
            <span>{fmt_money(@total)}</span>
          </div>
          <.table id="user_cart" rows={@cart}>
            <:col :let={item} label="Name">{item["label"]}</:col>
            <:col :let={item} label="Price">{fmt_money(item["price"])}</:col>
            <:col :let={item} label="Count">x{item["count"]}</:col>
          </.table>
        </div>
      <% end %>

      <div :if={@waiting_for_card}>Please insert card</div>
      <div :if={@checkout_in_progress}>Order in progress...</div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Shop.subscribe_cart()
    end

    socket =
      socket
      |> assign_cart(Shop.get_cart())

    {:ok, socket}
  end

  @impl true
  def handle_info({:cart, :updated}, socket) do
    {:noreply, assign_cart(socket, Shop.get_cart())}
  end

  @impl true
  def handle_info({:cart, :clear}, socket) do
    {:noreply, assign_cart(socket, [])}
  end

  defp assign_cart(socket, cart) do
    total = Shop.cart_total(cart)

    socket
    |> assign(:cart, cart)
    |> assign(:total, total)
  end
end
