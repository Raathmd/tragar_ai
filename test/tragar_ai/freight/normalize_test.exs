defmodule TragarAi.Freight.NormalizeTest do
  use ExUnit.Case, async: true

  alias TragarAi.Freight.Normalize

  test "waybills: extracts, joins items, transforms POD url, parses paging" do
    resp = %{
      "esWaybills" => %{
        "Waybills" => [
          %{
            "waybillNumber" => "WB1",
            "statusDescription" => "Delivered",
            "PODImageUrl" => "https://x/FreightWare/V2/system/pod/ABC123"
          }
        ],
        "Items" => [%{"waybillNumber" => "WB1", "lineNumber" => 1, "description" => "Box"}],
        "wtPaging" => [%{"totalRecords" => "5", "totalPages" => "1", "pageNumber" => 1}]
      }
    }

    assert %{"waybills" => [wb], "paging" => paging} = Normalize.waybills(resp)
    assert wb["waybill_number"] == "WB1"
    assert wb["status_description"] == "Delivered"

    # Env-agnostic: the key is appended to the configured POD viewer base (prod
    # vs UAT is a config concern — see PodUrlTest).
    assert wb["pod_image_url"] =~ "/views/viewImage.html?ABC123"

    assert [%{"description" => "Box", "line_number" => 1}] = wb["items"]
    assert paging["total_records"] == "5"
  end

  test "rates: reads the singular `Rate` key under esRates" do
    resp = %{"esRates" => %{"Rate" => [%{"serviceType" => "ON", "totalCharge" => 100.0}]}}
    assert [%{"service_type" => "ON", "total_charge" => 100.0}] = Normalize.rates(resp)
  end

  test "sites: maps siteReference -> site_code" do
    resp = %{"esSites" => %{"Sites" => [%{"siteReference" => "JHB01", "siteName" => "Depot"}]}}
    assert [%{"site_code" => "JHB01", "site_name" => "Depot"}] = Normalize.sites(resp)
  end

  test "tracking: nests POD with its quirky casing" do
    resp = %{
      "esTrackAndTrace" => %{
        "TrackAndTrace" => [
          %{
            "eventDescription" => "Delivered",
            "POD" => %{
              "PODDate" => "2026-06-15",
              "receiverName" => "J. Smith",
              "PODImageURL" => "u"
            }
          }
        ]
      }
    }

    assert [event] = Normalize.tracking(resp)
    assert event["event_description"] == "Delivered"
    assert event["pod"]["pod_date"] == "2026-06-15"
    assert event["pod"]["receiver_name"] == "J. Smith"
  end

  test "service_types: projects to code/name/description" do
    resp = %{
      "esServiceTypes" => %{
        "ServiceTypes" => [%{"serviceTypeCode" => "ON", "serviceTypeDescription" => "Overnight"}]
      }
    }

    assert [%{"code" => "ON", "name" => "Overnight"}] = Normalize.service_types(resp)
  end

  test "quote_created: pulls obj + number with fallback" do
    assert %{"quote_obj" => "Q1", "quote_number" => "Q1"} =
             Normalize.quote_created(%{"quoteObj" => "Q1"})
  end

  test "branches: extracts codes/names, ignores Paging" do
    resp = %{
      "esBranches" => %{
        "Branches" => [
          %{
            "branchCode" => "JHB",
            "branchName" => "JOHANNESBURG",
            "organisationCode" => "Tragar",
            "organisationName" => "Tragar"
          }
        ],
        "Paging" => []
      }
    }

    assert [b] = Normalize.branches(resp)
    assert b["branch_code"] == "JHB"
    assert b["branch_name"] == "JOHANNESBURG"
    assert b["organisation_code"] == "Tragar"
  end

  test "branches: [] when the wrapper is missing" do
    assert Normalize.branches(%{}) == []
  end
end
