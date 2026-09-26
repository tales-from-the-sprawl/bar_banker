defmodule BarBanker do
  @moduledoc """
  BarBanker keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  alias BarBanker.Kiosk.{Browsers, Cog}

  @doc """
  Reloads the page in every screen's `cog` browser window.

  Returns each screen's result keyed by screen id, e.g.
  `[customer: :ok, staff: {:error, reason}]`.
  """
  @spec reload_browsers() :: [{atom(), :ok | {:error, term()}}]
  def reload_browsers do
    Enum.map(Browsers.app_ids(), fn {id, app_id} -> {id, Cog.reload(app_id)} end)
  end
end
