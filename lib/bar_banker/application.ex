defmodule BarBanker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        # Children for all targets
        BarBanker.Shop.Cart
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
        {LibNFC.Mock, []},
        {Task, fn -> start_nfc(client_state: {nil, :mock}, name: BarBanker.NFC) end}
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
        Supervisor.child_spec(
          {Task, fn -> start_nfc(client_state: {nil, :real}, name: BarBanker.NFC) end},
          id: :start_nfc
        ),
        # {BarBanker.Keypad, []},
        {Task, &start_node/0}
      ]
    end

    defp start_node() do
      {_, 0} = System.cmd("epmd", ~w"-daemon")
      _ = Node.start(:"bar_banker@bar_banker.local")
      Node.set_cookie(Application.get_env(:mix_tasks_upload_hotswap, :cookie))
    end
  end

  @nfc_retry_ms 5_000

  # Runs outside the main supervision tree's synchronous startup: a `Supervisor`
  # always treats a child's *first* start failure as fatal to the whole
  # supervisor, regardless of that child's `:restart` setting — that only
  # governs restarts after a successful start. So if the NFC reader can't be
  # opened yet (unplugged, still powering up, transient I2C hiccup, ...),
  # starting it from inside a one-off `Task` — and retrying here instead of
  # giving up — keeps that failure from ever reaching `BarBanker.Supervisor`
  # and taking down the whole app (and with it, firmware validation).
  defp start_nfc(opts) do
    case BarBanker.NFC.start_link(opts) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("BarBanker.NFC failed to start (#{inspect(reason)}), retrying...")
        Process.sleep(@nfc_retry_ms)
        start_nfc(opts)
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
