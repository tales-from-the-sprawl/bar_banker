defmodule BarBankerWeb.MenuLive do
  use BarBankerWeb, :live_view
  alias BarBanker.Shop
  import BarBanker.Utils, only: [fmt_money: 1]

  @impl true
  def render(assigns) do
    ~H"""
    <.table id="menu" rows={@items}>
      <:col :let={{{slug, item}, index}} label="Name">
        <kbd
          :if={key = index_key(index)}
          class="kbd"
          phx-window-keydown={menu_action(slug, item, @path)}
          phx-key={key}
        >{key}</kbd>
        {item["label"]}
      </:col>
      <:col :let={{{_slug, item}, _index}} label="Price">{fmt_money(item["price"])}</:col>
    </.table>
    <div class="flex gap-4 items-center">
      <span :if={@path != []}>
        <kbd class="kbd" phx-window-keydown="navigate_up" phx-key="Backspace">←</kbd> Back
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
      |> Enum.with_index()

    socket =
      socket
      |> assign(:path, path)
      |> assign(:items, items)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_cart", %{"repeat" => true}, socket) do
    {:noreply, socket}
  end

  def handle_event("add_cart", %{"slug" => slug}, socket) do
    path = socket.assigns.path ++ [slug]

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

  def handle_event("navigate_up", _payload, socket) do
    path = Enum.drop(socket.assigns.path, -1)
    {:noreply, push_patch(socket, to: menu_path(path))}
  end

  defp assign_cart(socket, cart) do
    total = Shop.cart_total(cart)

    socket
    |> assign(:cart, cart)
    |> assign(:total, total)
  end

  # Items are bound to 1-9 then 0 by position; anything past the tenth gets no key.
  defp index_key(index) when index < 9, do: Integer.to_string(index + 1)
  defp index_key(9), do: "0"
  defp index_key(_), do: nil

  defp menu_path([]), do: ~p"/menu"
  defp menu_path(path), do: ~p"/menu/#{path}"

  defp menu_action(slug, %{"children" => _}, path),
    do: JS.patch(menu_path(path ++ [slug]))

  defp menu_action(slug, _, _), do: JS.push("add_cart", value: %{slug: slug})
end
