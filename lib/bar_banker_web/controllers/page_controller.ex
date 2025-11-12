defmodule BarBankerWeb.PageController do
  use BarBankerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
