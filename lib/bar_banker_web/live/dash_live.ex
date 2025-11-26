defmodule BarBankerWeb.DashLive do
  require Logger
  alias Phoenix.LiveView.AsyncResult
  alias BarBanker.Sin
  alias BarBanker.Nfc
  alias BarBanker.Cart
  alias BarBanker.Inventory
  use BarBankerWeb, :live_view

  def mount(_params, _session, socket) do
    menu = Inventory.get_shop_items()
    cart = Cart.get()
    total = Cart.total()

    socket =
      socket
      |> assign(:view, :menu)
      |> assign(:menu, menu)
      |> assign(:sub_menu, nil)
      |> assign(:category, nil)
      |> assign(:cart, cart)
      |> assign(:total, total)
      |> assign(:message, nil)
      |> assign(:order, nil)

    {:ok, socket}
  end

  def handle_event("select_category", %{"code" => code, "repeat" => false}, socket) do
    sub_menu = Inventory.find(socket.assigns.menu, code)

    socket =
      socket
      |> assign(:sub_menu, sub_menu)
      |> assign(:category, code)

    {:noreply, socket}
  end

  def handle_event("select_category", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("unselect_category", _params, socket) do
    socket =
      socket
      |> assign(:sub_menu, nil)
      |> assign(:category, nil)

    {:noreply, socket}
  end

  def handle_event(
        "add_cart",
        %{"code" => code, "repeat" => false},
        socket
      ) do
    menu_item =
      socket.assigns.menu
      |> Inventory.find(socket.assigns.category, code)

    Cart.add(menu_item)

    socket =
      socket
      |> assign(:cart, Cart.get())
      |> assign(:total, Cart.total())
      |> assign(:sub_menu, nil)
      |> assign(:category, nil)

    {:noreply, socket}
  end

  def handle_event("add_cart", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("clear_cart", _params, socket) do
    if socket.assigns.sub_menu != nil do
      socket =
        socket
        |> assign(:sub_menu, nil)

      {:noreply, socket}
    else
      Cart.clear()

      socket =
        socket
        |> assign(:cart, [])
        |> assign(:total, 0)
        |> update(:order, &clear_order/1)

      {:noreply, socket}
    end
  end

  def handle_event("checkout", _params, socket) do
    socket =
      socket
      |> assign(:view, :cart)
      |> assign(:sub_menu, nil)
      |> assign(:category, nil)

    {:noreply, socket}
  end

  def handle_event("cancel_checkout", _params, socket) do
    socket =
      socket
      |> assign(:view, :menu)
      |> assign(:sub_menu, nil)
      |> assign(:category, nil)

    {:noreply, socket}
  end

  def handle_event("order", _params, socket) do
    # handle = "steve"

    total = socket.assigns.total

    socket =
      socket
      |> assign(:sub_menu, nil)
      |> assign(:category, nil)
      |> assign(:order, AsyncResult.loading())
      |> start_async(
        :order,
        fn ->
          # handle =
          #  Nfc.read()
          #  |> then(fn %{"data" => records} -> records end)
          #  |> Enum.find(&match?(%{type: "T"}, &1))
          #  |> then(fn %{text: code} -> code end)
          #  |> Sin.map_sincode()

          handle = "steve"

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
      |> assign(:cart, [])
      |> assign(:total, 0)

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
end
