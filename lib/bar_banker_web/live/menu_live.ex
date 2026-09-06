defmodule BarBankerWeb.MenuLive do
  use BarBankerWeb, :live_view
  alias BarBanker.Shop
  import BarBanker.Utils, only: [fmt_money: 1]

  @impl true
  def render(assigns) do
    ~H"""
    <.table id="menu" rows={@items}>
      <:col :let={{id, item}} label="Name">
        <kbd
          class="kbd"
          phx-window-keydown={menu_action(id, item, @path)}
          phx-key={item["key"]}
        >{item["key"]}</kbd>
        {item["label"]}
      </:col>
      <:col :let={{_id, item}} label="Price">{fmt_money(item["price"])}</:col>
    </.table>
    <div class="flex gap-4 items-center">
      <span>
        <kbd class="kbd" phx-window-keydown="unselect_category" phx-key="Escape">ESC</kbd> Back
      </span>
      <span>
        <kbd class="kbd" phx-window-keydown={JS.navigate(~p"/checkout")} phx-key="Enter">Enter</kbd>
        Checkout
      </span>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:inventory, Shop.get_shop_items())
      |> assign_cart(Shop.get_cart())

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"path" => path}, _uri, socket) do
    items =
      socket.assigns.inventory
      |> Shop.items(path)
      |> Enum.to_list()

    socket =
      socket
      |> assign(:path, path)
      |> assign(:items, items)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_cart", %{"code" => code, "repeat" => false}, socket) do
    path = socket.assigns.path ++ [code]

    menu_item =
      socket.assigns.inventory
      |> Shop.item(path)

    Shop.add_cart(path, menu_item)

    socket =
      socket
      |> assign_cart(Shop.get_cart())
      |> push_patch(to: ~p"/menu")

    {:noreply, socket}
  end

  def handle_event("add_cart", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_down", %{"code" => code}, socket) do
    path = Path.join(socket.assigns.path, code)
    {:noreply, push_patch(socket, to: ~p"/menu/#{path}")}
  end

  def handle_event("navigate_up", _payload, socket) do
    path = Path.join(socket.assigns.path) |> Path.dirname()
    {:noreply, push_patch(socket, to: ~p"/menu/#{path}")}
  end

  defp assign_cart(socket, cart) do
    total = Shop.cart_total(cart)

    socket
    |> assign(:cart, cart)
    |> assign(:total, total)
  end

  defp menu_action(id, %{"children" => _}, path),
    do: JS.patch(~p"/menu/#{Path.join(path, id)}")

  defp menu_action(_, _, _), do: "add_cart"
end
