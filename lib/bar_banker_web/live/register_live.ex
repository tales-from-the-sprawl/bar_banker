defmodule BarBankerWeb.RegisterLive do
  use BarBankerWeb, :live_view
  require Logger
  alias Phoenix.LiveView.AsyncResult
  alias BarBanker.Sin
  alias BarBanker.Nfc
  alias BarBanker.Cart
  alias BarBanker.Inventory

  def mount(_params, _session, socket) do
    inventory = Inventory.get_shop_items()

    socket =
      socket
      |> assign(:view, :menu)
      |> assign(:inventory, inventory)
      |> assign_cart(Cart.get())
      |> assign(:message, nil)
      |> assign(:order, nil)

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
    Cart.clear()

    socket =
      socket
      |> assign_cart([])
      |> update(:order, &clear_order/1)

    {:noreply, socket}
  end

  def handle_event("checkout", _params, socket) do
    socket =
      socket
      |> assign(:view, :cart)
      |> push_patch(to: ~p"/")

    {:noreply, socket}
  end

  def handle_event("cancel_checkout", _params, socket) do
    socket =
      socket
      |> assign(:view, :menu)
      |> push_patch(to: ~p"/")

    {:noreply, socket}
  end

  def handle_event("order", _params, socket) do
    total = socket.assigns.total

    socket =
      socket
      |> push_patch(to: ~p"/")
      |> assign(:order, AsyncResult.loading())
      |> start_async(
        :order,
        fn ->
          handle =
            Nfc.read()
            |> then(fn %{"data" => records} -> records end)
            |> Enum.find(&match?(%{type: "T"}, &1))
            |> then(fn %{text: code} -> code end)
            |> Sin.map_sincode()

          if handle == nil do
            {:error, "Invalid card"}
          else
            Logger.debug("Transfering #{total} from #{handle}")

            resp =
              Req.post!("https://talesbot.databladet.se/api/transfer",
                auth: {:basic, "tales:IP*OHtkgR5CTi7Gcr6Bao#v0!AGrDKDj"},
                json: %{"sender" => handle, "receiver" => "trinity_taskbar", "amount" => total}
              ).body

            case resp do
              %{"status" => "ok", "message" => message, "amount" => transfered} ->
                Logger.debug("Transfering #{total} from #{handle}")
                {:ok, %{order: {message, transfered}}}

              %{"status" => "error", "msg" => reason} ->
                Logger.error("Failed to transfer #{total} from #{handle}, reason: #{reason}")
                {:error, reason}
            end
          end
        end
      )

    {:noreply, socket}
  end

  def handle_async(:order, {:ok, {:ok, %{order: {message, _}}}}, socket) do
    %{order: order} = socket.assigns

    Cart.clear()

    socket =
      socket
      |> assign(:order, AsyncResult.ok(order, message))
      |> assign(:view, :menu)
      |> assign_cart([])

    Process.send_after(self(), :clear_message, 10000)

    {:noreply, socket}
  end

  def handle_async(:order, {:ok, {:error, reason}}, socket) do
    %{order: order} = socket.assigns

    socket =
      socket
      |> assign(:order, AsyncResult.failed(order, reason))

    Process.send_after(self(), :clear_message, 10000)

    {:noreply, socket}
  end

  def handle_async(:order, {:exit, reason}, socket) do
    %{order: order} = socket.assigns

    socket =
      socket
      |> assign(:order, AsyncResult.failed(order, {:exit, reason}))

    {:noreply, assign(socket, :order, AsyncResult.failed(order, {:exit, reason}))}
  end

  def handle_info(:clear_message, socket) do
    socket =
      socket
      |> update(:order, &clear_order/1)

    {:noreply, socket}
  end

  defp clear_order(nil), do: nil

  defp clear_order(%AsyncResult{} = v) do
    if v.ok? do
      nil
    else
      v
    end
  end

  defp menu_action(%{"children" => _}), do: "select_category"
  defp menu_action(_), do: "add_cart"

  defp assign_cart(socket, cart) do
    total = Cart.total(cart)

    socket
    |> assign(:cart, cart)
    |> assign(:total, total)
  end

  defp fmt_money(amount) when is_integer(amount), do: "¥#{amount}"
  defp fmt_money(_), do: ""
end
