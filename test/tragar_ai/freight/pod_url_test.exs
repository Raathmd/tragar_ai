defmodule TragarAi.Freight.PodUrlTest do
  # async: false — swaps the Dovetail config to prove the POD url follows it.
  use ExUnit.Case, async: false

  alias TragarAi.Freight.Normalize

  test "waybill POD url follows the configured pod_image_base (prod), not a hardcoded env" do
    original = Application.get_env(:tragar_ai, TragarAi.Dovetail.Client, [])
    prod_base = "https://tragar-db.dovetail.co.za/FWO/views/viewImage.html"

    Application.put_env(
      :tragar_ai,
      TragarAi.Dovetail.Client,
      Keyword.put(original, :pod_image_base, prod_base)
    )

    on_exit(fn -> Application.put_env(:tragar_ai, TragarAi.Dovetail.Client, original) end)

    wb = Normalize.waybill(%{"waybillNumber" => "WB1", "PODImageUrl" => "https://x/system/pod/ABC123"})

    assert wb["pod_image_url"] == prod_base <> "?ABC123"
  end
end
