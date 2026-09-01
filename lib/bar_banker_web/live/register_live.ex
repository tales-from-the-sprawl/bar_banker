defmodule BarBankerWeb.RegisterLive do
  alias BarBanker.Client
  use BarBankerWeb, :live_view
  alias BarBanker.NFC
  alias BarBanker.Cart
  alias BarBanker.Inventory

  @shop_handle "trinity_taskbar"

  def mount(_params, _session, socket) do
    if connected?(socket) do
      NFC.subscribe_nfc()
    end

    inventory = Inventory.get_shop_items()

    socket =
      socket
      |> assign(:view, :menu)
      |> assign(:inventory, inventory)
      |> assign_cart(Cart.get())
      |> assign(:waiting_for_card, false)
      |> assign(:checkout_in_progress, false)

    {:ok, socket}
  end

  def handle_params(%{"path" => path}, _uri, socket) do
    items =
      socket.assigns.inventory
      |> Inventory.items(path)
      |> Enum.to_list()

    socket =
      socket
      |> assign(:path, path)
      |> assign(:items, items)

    {:noreply, socket}
  end

  def handle_event("select_category", %{"code" => code, "repeat" => false}, socket) do
    path =
      socket.assigns.path
      |> Path.join(code)

    socket =
      socket
      |> push_patch(to: ~p"/#{path}")

    {:noreply, socket}
  end

  def handle_event("select_category", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("unselect_category", _params, socket) do
    path =
      [socket.assigns.path]
      |> List.pop_at(-1)
      |> then(fn
        {_, []} -> [""]
        {_, v} -> v
      end)
      |> Path.join()

    socket =
      socket
      |> push_patch(to: ~p"/#{path}")

    {:noreply, socket}
  end

  def handle_event("add_cart", %{"code" => code, "repeat" => false}, socket) do
    path = socket.assigns.path ++ [code]

    menu_item =
      socket.assigns.inventory
      |> Inventory.item(socket.assigns.path ++ [code])

    Cart.add(path, menu_item)

    socket =
      socket
      |> assign_cart(Cart.get())
      |> push_patch(to: ~p"/")

    {:noreply, socket}
  end

  def handle_event("add_cart", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("clear_cart", _params, socket) do
    socket =
      socket
      |> assign_cart(Cart.clear())

    {:noreply, socket}
  end

  def handle_event("to_cart", _params, socket) do
    socket =
      socket
      |> assign_view(:cart)

    {:noreply, socket}
  end

  def handle_event("to_menu", _params, socket) do
    socket =
      socket
      |> assign_view(:menu)

    {:noreply, socket}
  end

  def handle_event("checkout", _params, socket) when is_nil(socket.assigns.current_tag) do
    socket =
      socket
      |> assign(:waiting_for_card, true)

    {:noreply, socket}
  end

  def handle_event("checkout", _params, socket) do
    current_tag = socket.assigns.current_tag
    total = socket.assigns.total

    socket =
      socket
      |> start_checkout(current_tag, @shop_handle, total)

    {:noreply, socket}
  end

  def handle_async(:checkout, {:ok, {message, _amount}}, socket) do
    Cart.clear()

    socket =
      socket
      |> assign(:checkout_in_progress, false)
      |> assign_view(:menu)
      |> assign_cart([])
      |> put_flash(:info, message)

    {:noreply, socket}
  end

  def handle_async(:checkout, {:exit, reason}, socket) do
    socket =
      socket
      |> assign(:checkout_in_progress, false)
      |> put_flash(:error, reason)

    {:noreply, socket}
  end

  def handle_info({:nfc, :in, uid}, %{assigns: %{waiting_for_card: true}} = socket) do
    total = socket.assigns.total

    socket =
      socket
      |> start_checkout(uid, @shop_handle, total)
      |> assign(:current_tag, uid)

    {:noreply, socket}
  end

  def handle_info({:nfc, :in, uid}, socket) do
    socket =
      socket
      |> assign(:current_tag, uid)

    {:noreply, socket}
  end

  def handle_info({:nfc, :out, _uid}, socket) do
    socket =
      socket
      |> assign(:current_tag, nil)

    {:noreply, socket}
  end

  defp start_checkout(socket, sender, receiver, total) do
    socket
    |> assign(:checkout_in_progress, true)
    |> start_async(:checkout, fn ->
      case Client.transfer(sender, receiver, total) do
        {:ok, res} -> res
        {:error, reason} -> raise reason
      end
    end)
  end

  defp menu_action(id, %{"children" => _}, path),
    do: JS.patch(~p"/#{Path.join(path ++ [id])}")

  defp menu_action(_, _, _), do: "add_cart"

  defp assign_cart(socket, cart) do
    total = Cart.total(cart)

    socket
    |> assign(:cart, cart)
    |> assign(:total, total)
  end

  defp assign_view(socket, view) do
    socket
    |> assign(:view, view)
    |> push_patch(to: ~p"/")
  end

  defp fmt_money(amount) when is_integer(amount), do: "¥#{amount}"
  defp fmt_money(_), do: ""
end
