defmodule BarBankerWeb.Router do
  use BarBankerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BarBankerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BarBankerWeb do
    pipe_through :browser

    # One screen per physical output — see BarBanker.Kiosk.Browsers, which
    # points one cog window at each of these. `live_action` (:customer /
    # :staff) tells RegisterLive which screen it is rendering for.
    live "/customer/*path", RegisterLive, :customer
    live "/staff/*path", RegisterLive, :staff
  end

  # Other scopes may use custom stacks.
  # scope "/api", BarBankerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:bar_banker, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BarBankerWeb.Telemetry
    end
  end
end
