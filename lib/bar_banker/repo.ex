defmodule BarBanker.Repo do
  use Ecto.Repo,
    otp_app: :bar_banker,
    adapter: Ecto.Adapters.Postgres
end
