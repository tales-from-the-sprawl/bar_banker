defmodule BarBanker.Kiosk.Browsers do
  @moduledoc """
  One `cog` browser window per physical output.

  Each entry's `app_id` is matched to a Wayland output via `app-ids=` in
  `/etc/xdg/weston/weston.ini` (rootfs_overlay) — see that file for which
  physical HDMI port shows which screen.

  weston's kiosk-shell gives keyboard focus to whichever surface was mapped
  last, and the staff screen is the one that needs the keyboard. So the order
  of `@screens` matters: the staff screen comes last, and its `wait_for`
  additionally blocks until the customer `cog` answers on D-Bus (plus a short
  grace period for its window to map). `MuonTrap.Daemon` runs `wait_for` in
  a background task, so list order alone wouldn't guarantee which process
  actually spawns first.

  Kept as its own supervisor, separate from `BarBanker.Kiosk.Supervisor`'s
  chain, so browser crashes don't take down weston/dbus. It's `:rest_for_one`
  so a crash of the staff browser restarts only that window, while a crash
  of the customer browser also restarts the staff one after it — otherwise
  the respawned customer window would steal keyboard focus.
  """
  use Supervisor

  require Logger

  alias BarBanker.Kiosk.Cog

  @poll_ms 500
  @max_retries 20
  @map_grace_ms 1_000

  # Order matters: the staff screen must stay last (see moduledoc).
  @screens [
    %{
      id: :customer,
      app_id: "se.databladet.bar_banker.customer",
      url: "http://localhost:4000/customer"
    },
    %{
      id: :staff,
      app_id: "se.databladet.bar_banker.staff",
      url: "http://localhost:4000/menu"
    }
  ]

  @doc "The `--gapplication-app-id` of each screen's `cog` instance, keyed by screen id."
  @spec app_ids() :: [{atom(), String.t()}]
  def app_ids, do: Enum.map(@screens, &{&1.id, &1.app_id})

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(args) do
    env = Keyword.fetch!(args, :env)
    wait_for = Keyword.fetch!(args, :wait_for)

    {staff, others} = Enum.split_with(@screens, &(&1.id == :staff))

    staff_wait_for = fn ->
      wait_for.()
      Enum.each(others, &wait_for_cog(&1.app_id))
    end

    children =
      Enum.map(others, &cog_spec(&1, env, wait_for)) ++
        Enum.map(staff, &cog_spec(&1, env, staff_wait_for))

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Best-effort: if the other window never shows up, start the staff browser
  # anyway rather than leaving the staff screen blank.
  defp wait_for_cog(app_id, retries \\ @max_retries)

  defp wait_for_cog(app_id, 0) do
    Logger.warning("BarBanker.Kiosk.Browsers: #{app_id} did not come up, starting staff anyway")
  end

  defp wait_for_cog(app_id, retries) do
    if cog_up?(app_id) do
      Process.sleep(@map_grace_ms)
    else
      Process.sleep(@poll_ms)
      wait_for_cog(app_id, retries - 1)
    end
  end

  defp cog_up?(app_id) do
    Cog.ping(app_id) == :ok
  catch
    _kind, _reason -> false
  end

  defp cog_spec(screen, env, wait_for) do
    Supervisor.child_spec(
      {MuonTrap.Daemon,
       [
         "cog",
         [
           "--platform=wl",
           "--gapplication-app-id=#{screen.app_id}",
           screen.url
         ] ++ Myelin.browser_args(),
         [
           env: env,
           stderr_to_stdout: true,
           log_output: :info,
           log_prefix: "cog[#{screen.id}]: ",
           wait_for: wait_for
         ]
       ]},
      id: screen.id
    )
  end
end
