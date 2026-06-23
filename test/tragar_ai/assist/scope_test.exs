defmodule TragarAi.Assist.ScopeTest do
  use ExUnit.Case, async: true
  alias TragarAi.Assist.Scope

  test "within? allows facts on an authorized account, denies others" do
    assert Scope.within?(%{"account_reference" => "ITD02"}, ["ITD01", "ITD02"])
    refute Scope.within?(%{"account_reference" => "OTHER"}, ["ITD02"])
  end

  test "within? allows non-account facts, denies account facts with no scope" do
    assert Scope.within?(%{"service_types" => []}, [])
    refute Scope.within?(%{"account_reference" => "ITD02"}, [])
  end

  test "account_allowed? is strict — needs a validated scope" do
    assert Scope.account_allowed?("ITD02", ["ITD02"])
    refute Scope.account_allowed?("ITD02", ["ITD01"])
    refute Scope.account_allowed?("ITD02", [])
  end
end
