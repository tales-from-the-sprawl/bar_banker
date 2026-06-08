defmodule BarBanker.Client do
  @base_url Application.compile_env!(:bar_banker, :base_url)
  @auth Application.compile_env!(:bar_banker, :auth)

  def new() do
    Req.new(
      base_url: @base_url,
      auth: @auth
    )
  end

  def balance(handle) when is_binary(handle) do
    new()
    |> Req.get(url: "/api/balance/:handle", path_params: [handle: handle]).body
  end

  def transfer(sender, receiver, amount, opts \\ []) do
    allow_partial = Keyword.get(opts, :partial, false)

    new()
    |> Req.post(
      url: "/api/transfer",
      json: %{
        sender: sender,
        receiver: receiver,
        amount: amount,
        allow_partial: allow_partial
      }
    ).body
  end
end
