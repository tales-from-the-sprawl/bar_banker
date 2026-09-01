defmodule BarBanker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Children for all targets
        BarBanker.Cart
      ] ++ phoenix_children() ++ children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BarBanker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  if Mix.target() == :host do
    defp children() do
      [
        # Children that only run on the host
        # Starts a worker by calling: BarBanker.Worker.start_link(arg)
        # {BarBanker.Worker, arg},
      ]
    end
  else
    defp children() do
      # NOTE: work around to stop watchers on targets
      Application.get_env(:bar_banker, BarBankerWeb.Endpoint)
      |> Keyword.put(:watchers, [])
      |> then(&Application.put_env(:bar_banker, BarBankerWeb.Endpoint, &1))

      [
        # Children for all targets except host
        # Starts a worker by calling: BarBanker.Worker.start_link(arg)
        # {BarBanker.Worker, arg},
        {BarBanker.Kiosk.Udevd, []},
        {BarBanker.Kiosk.Supervisor, []},
        {BarBanker.NFC, []},
        {BarBanker.Keypad, []},
        {Task, &start_node/0}
      ]
    end

    defp start_node() do
      {_, 0} = System.cmd("epmd", ~w"-daemon")
      _ = Node.start(:"bar_banker@bar_banker.local")
      Node.set_cookie(Application.get_env(:mix_tasks_upload_hotswap, :cookie))
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BarBankerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp phoenix_children do
    [
      BarBankerWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:bar_banker, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BarBanker.PubSub},
      BarBankerWeb.Endpoint
    ]
  end
end
