defmodule BarBankerWeb.CheckoutLive do
  use BarBankerWeb, :live_view
  alias BarBanker.NFC
  alias BarBanker.Shop
  import BarBanker.Utils, only: [fmt_money: 1]

  @impl true
  def render(assigns) do
    ~H"""
    <.table id="cart" rows={@cart}>
      <:col :let={item} label="Name">{item["label"]}</:col>
      <:col :let={item} label="Count">x{item["count"]}</:col>
      <:col :let={item} label="Price">{fmt_money(item["price"])}</:col>
      <:footer>
        <th scope="row" colspan="2" class="text-right">Order total</th>
        <td>{fmt_money(@total)}</td>
      </:footer>
    </.table>
    <div class="">
      <div class="flex gap-4 items-center">
        <span phx-window-keydown={JS.navigate(~p"/menu")} phx-key="Escape">
          <kbd class="kbd">ESC</kbd> Back
        </span>
        <span phx-window-keydown="clear_cart" phx-key="c">
          <kbd class="kbd">C</kbd> Clear
        </span>
        <span phx-window-keydown="checkout" phx-key="Enter">
          <kbd class="kbd">Enter</kbd> Order
        </span>
      </div>
    </div>

    <div :if={@waiting_for_card}>Please insert card</div>
    <div :if={@checkout_in_progress}>Order in progress...</div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:waiting_for_card, false)
      |> assign(:checkout_in_progress, false)
      |> assign_cart(Shop.get_cart())

    {:ok, socket}
  end

  @impl true
  def handle_event("clear_cart", _params, socket) do
    socket =
      socket
      |> cancel_async(:wait_for_tag)
      |> assign(:waiting_for_card, false)
      |> assign_cart(Shop.clear_cart())

    {:noreply, socket}
  end

  def handle_event("checkout", _params, socket)
      when socket.assigns.cart == [] or socket.assigns.waiting_for_card or
             socket.assigns.checkout_in_progress do
    {:noreply, socket}
  end

  def handle_event("checkout", _params, socket) do
    # The reader only polls while asked to: keep asking until a card shows
    # up. The task dies with this LiveView, which stops the polling.
    socket =
      socket
      |> assign(:waiting_for_card, true)
      |> start_async(:wait_for_tag, &NFC.wait_for_tag/0)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:wait_for_tag, {:ok, uid}, socket) do
    socket =
      socket
      |> assign(:waiting_for_card, false)
      |> start_checkout(uid, socket.assigns.total)

    {:noreply, socket}
  end

  def handle_async(:wait_for_tag, {:exit, reason}, socket) do
    socket =
      socket
      |> assign(:waiting_for_card, false)
      |> put_flash(:error, "Card reader failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  def handle_async(:checkout, {:ok, {message, _amount}}, socket) do
    Shop.clear_cart()

    socket =
      socket
      |> assign(:checkout_in_progress, false)
      |> push_navigate(~p"/menu")
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

  defp start_checkout(socket, sender, total) do
    socket
    |> assign(:checkout_in_progress, true)
    |> start_async(:checkout, fn ->
      case Shop.checkout(sender, total) do
        {:ok, res} -> res
        {:error, reason} -> raise reason
      end
    end)
  end

  defp assign_cart(socket, cart) do
    total = Shop.cart_total(cart)

    socket
    |> assign(:cart, cart)
    |> assign(:total, total)
  end
end
