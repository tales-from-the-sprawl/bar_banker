defmodule BarBankerWeb.MenuLiveTest do
  use BarBankerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BarBanker.Shop

  setup do
    Shop.clear_cart()
    on_exit(&Shop.clear_cart/0)
  end

  test "binds numeric keys to categories by position", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/menu")

    assert html =~ "Food"
    assert html =~ "Monies (tips)"

    render_keydown(element(view, "kbd[phx-key=\"3\"]"), %{"key" => "3"})
    assert_patch(view, ~p"/menu/drinks")
    assert render(view) =~ "Shaman Swizzle"
  end

  test "adds the item at the pressed index to the cart", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/menu/drinks")

    render_keydown(element(view, "kbd[phx-key=\"2\"]"), %{"key" => "2"})
    assert_patch(view, ~p"/menu")

    assert [%{"label" => "Shanghai Screamer", "count" => 1}] = Shop.get_cart()
  end

  test "escape navigates back to the top-level menu", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/menu")
    refute html =~ "Back"

    {:ok, view, _html} = live(conn, ~p"/menu/drinks")
    render_keydown(element(view, "kbd[phx-key=\"Escape\"]"), %{"key" => "Escape"})
    assert_patch(view, ~p"/menu")
    refute render(view) =~ "Back"
  end
end
