defmodule TragarAi.Freight.PodUrlTest do
  # async: false — swaps the Dovetail config to prove the POD url derives from it.
  use ExUnit.Case, async: false

  alias TragarAi.Freight.Normalize

  test "POD url derives from the configured base url (prod base → FWO viewer)" do
    original = Application.get_env(:tragar_ai, TragarAi.Dovetail.Client, [])

    prod =
      original
      |> Keyword.put(:base_url, "https://tragar-db.dovetail.co.za/WebServices/web")
      |> Keyword.delete(:pod_image_base)

    Application.put_env(:tragar_ai, TragarAi.Dovetail.Client, prod)
    on_exit(fn -> Application.put_env(:tragar_ai, TragarAi.Dovetail.Client, original) end)

    wb =
      Normalize.waybill(%{
        "waybillNumber" => "WB1",
        "PODImageUrl" => "https://x/system/pod/ABC123"
      })

    assert wb["pod_image_url"] ==
             "https://tragar-db.dovetail.co.za/FWO/views/viewImage.html?ABC123"
  end
end
