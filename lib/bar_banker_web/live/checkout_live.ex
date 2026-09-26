defmodule BarBankerWeb.CheckoutLive do
  use BarBankerWeb, :live_view
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
        <span phx-window-keydown={JS.navigate(~p"/menu")} phx-key="Backspace">
          <kbd class="kbd">←</kbd> Back
        </span>
        <span phx-window-keydown="clear_cart" phx-key=".">
          <kbd class="kbd">Del</kbd> Clear
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
      |> cancel_async(:wait_for_card)
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
      |> start_async(:wait_for_card, &Shop.wait_for_card/0)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:wait_for_card, {:ok, {:ok, card}}, socket) do
    socket =
      socket
      |> assign(:waiting_for_card, false)
      |> start_checkout(card, socket.assigns.total)

    {:noreply, socket}
  end

  def handle_async(:wait_for_card, {:ok, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(:waiting_for_card, false)
      |> put_flash(:error, "Card not accepted: #{format_error(reason)}")

    {:noreply, socket}
  end

  def handle_async(:wait_for_card, {:exit, reason}, socket) do
    socket =
      socket
      |> assign(:waiting_for_card, false)
      |> put_flash(:error, "Card reader failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  def handle_async(:checkout, {:ok, {:ok, {message, _amount}}}, socket) do
    Shop.clear_cart()

    socket =
      socket
      |> assign(:checkout_in_progress, false)
      |> push_navigate(~p"/menu")
      |> put_flash(:info, message)

    {:noreply, socket}
  end

  def handle_async(:checkout, {:ok, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(:checkout_in_progress, false)
      |> put_flash(:error, "Payment failed: #{format_error(reason)}")

    {:noreply, socket}
  end

  def handle_async(:checkout, {:exit, reason}, socket) do
    socket =
      socket
      |> assign(:checkout_in_progress, false)
      |> put_flash(:error, "Payment failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  defp start_checkout(socket, card, total) do
    socket
    |> assign(:checkout_in_progress, true)
    |> start_async(:checkout, fn -> Shop.checkout(card, total) end)
  end

  defp format_error(:insufficient_funds), do: "insufficient funds"
  defp format_error(:card_not_recognized), do: "card not recognized"
  defp format_error(:no_text_record), do: "card not recognized"

  defp format_error({:reconciliation_required, _details}),
    do: "card may be out of sync, contact staff"

  defp format_error(message) when is_binary(message), do: message
  defp format_error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format_error(reason), do: inspect(reason)

  defp assign_cart(socket, cart) do
    total = Shop.cart_total(cart)

    socket
    |> assign(:cart, cart)
    |> assign(:total, total)
  end
end
