defmodule BarBanker.Kiosk.Cog do
  @moduledoc """
  D-Bus client for the Cog browser.

  Cog exports an `org.gtk.Actions` action group on the session bus at a
  service/object path derived from its `--gapplication-app-id` (dots become
  slashes: `se.databladet.bar_banker.customer` →
  `/se/databladet/bar_banker/customer`). Since `BarBanker.Kiosk.Browsers`
  runs one `cog` instance per screen, every function here takes that
  instance's app id so the caller says which screen it means. Calling
  `org.gtk.Actions.Activate(name, params, platform_data)` triggers actions
  registered by `cog-launcher.c`: `open` (URL), `previous`, `next`, `reload`,
  `quit`.

  See `cogctl(1)` and the source at `launcher/cogctl.c` in the Cog repo.
  """

  require Record

  Record.defrecordp(:dbus_variant, :dbus_variant, type: :string, value: "")

  @actions_iface "org.gtk.Actions"
  @peer_iface "org.freedesktop.DBus.Peer"

  @spec open_url(String.t(), String.t()) :: :ok | {:error, term()}
  def open_url(app_id, url) when is_binary(app_id) and is_binary(url) do
    activate(app_id, "open", [variant(:string, url)])
  end

  @spec back(String.t()) :: :ok | {:error, term()}
  def back(app_id), do: activate(app_id, "previous", [])

  @spec forward(String.t()) :: :ok | {:error, term()}
  def forward(app_id), do: activate(app_id, "next", [])

  @spec reload(String.t()) :: :ok | {:error, term()}
  def reload(app_id), do: activate(app_id, "reload", [])

  @spec quit(String.t()) :: :ok | {:error, term()}
  def quit(app_id), do: activate(app_id, "quit", [])

  @spec ping(String.t()) :: :ok | {:error, term()}
  def ping(app_id), do: call(app_id, @peer_iface, "Ping", [])

  defp activate(app_id, action_name, params) when is_binary(action_name) and is_list(params) do
    call(app_id, @actions_iface, "Activate", [action_name, params, %{}])
  end

  # The bus, service, and object proxies are cached gen_servers — keep them
  # alive across calls. Releasing the object stops the service, which then
  # leaves a stale pid in dbus_bus_reg's cache for the next call.
  defp call(app_id, iface_name, method_name, args) do
    with {:ok, bus} <- :dbus_bus_reg.get_bus(:session),
         {:ok, service} <- :dbus_bus.get_service(bus, app_id),
         {:ok, proxy} <- :dbus_remote_service.get_object(service, object_path(app_id)) do
      normalize(:dbus_proxy.call(proxy, iface_name, method_name, args))
    end
  end

  defp object_path(app_id), do: "/" <> String.replace(app_id, ".", "/")

  defp variant(type, value), do: dbus_variant(type: type, value: value)

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, _} = err), do: err
end
