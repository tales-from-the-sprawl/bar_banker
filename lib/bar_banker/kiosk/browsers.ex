defmodule BarBanker.Kiosk.Browsers do
  @moduledoc """
  One `cog` browser window per physical output.

  Each entry's `app_id` is matched to a Wayland output via `app-ids=` in
  `/etc/xdg/weston/weston.ini` (rootfs_overlay) — see that file for which
  physical HDMI port shows which screen.

  Kept as its own plain `:one_for_one` supervisor, rather than folded
  straight into `BarBanker.Kiosk.Supervisor`'s `:rest_for_one` chain, so that
  a crash in one screen's browser process restarts only that window and
  leaves the other screen alone.
  """
  use Supervisor

  @screens [
    %{
      id: :customer,
      app_id: "se.databladet.bar_banker.customer",
      url: "http://localhost:4000/customer"
    },
    %{
      id: :staff,
      app_id: "se.databladet.bar_banker.staff",
      url: "http://localhost:4000/staff"
    }
  ]

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Supervisor
  def init(args) do
    env = Keyword.fetch!(args, :env)
    wait_for = Keyword.fetch!(args, :wait_for)

    children = Enum.map(@screens, &cog_spec(&1, env, wait_for))

    Supervisor.init(children, strategy: :one_for_one)
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
