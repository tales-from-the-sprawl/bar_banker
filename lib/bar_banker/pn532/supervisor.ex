defmodule BarBanker.PN532.Supervisor do
  @moduledoc """
  Starts one supervised `BarBanker.PN532.Server` per configured SPI bus, so
  multiple processes can share a PN532 connection instead of each opening
  its own raw SPI handle, and it reconnects automatically after failures
  or crashes.

  Buses are read from `config :bar_banker, #{inspect(__MODULE__)}, buses: [...]`,
  and `low_power: true` in the same config starts every server in
  low-power mode (see `BarBanker.PN532.Server`).
  The `Registry` used to look servers up by bus name is started as the
  first child under `:rest_for_one`: if it ever crashes, its registrations
  are lost, so the `Server`s (which only register once, at `start_link`)
  must restart alongside it rather than being silently orphaned.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(_args) do
    config = Application.get_env(:bar_banker, __MODULE__, [])
    buses = config[:buses] || []
    server_opts = Keyword.take(config, [:low_power])

    children =
      [{Registry, keys: :unique, name: BarBanker.PN532.Registry}] ++
        Enum.map(buses, fn bus_name ->
          Supervisor.child_spec({BarBanker.PN532.Server, bus_name},
            id: {BarBanker.PN532.Server, bus_name},
            start: {BarBanker.PN532.Server, :start_link, [bus_name, server_opts]}
          )
        end)

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
