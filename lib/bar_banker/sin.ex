defmodule BarBanker.Sin do
  def get_sin_values() do
    :code.priv_dir(:bar_banker)
    |> Path.join("data/sin.json")
    |> File.read!()
    |> JSON.decode!()
  end

  def map_sincode(sincode) do
    get_sin_values()[sincode]
  end
end
