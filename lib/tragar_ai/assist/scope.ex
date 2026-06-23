defmodule TragarAi.Assist.Scope do
  @moduledoc """
  Account scoping for read facts.

  Direct lookups (waybill/quote/invoice by id) fetch by key and don't themselves
  enforce ownership. When a request carries a **validated** account scope — the
  account(s) we derived from the Freshdesk requester — the fetched fact must
  belong to it. Reference data with no `account_reference` (service types, stock)
  is never restricted.

  The scope must come from a validated source (the requester gate), never a
  caller-supplied argument, or it provides no protection.
  """

  @doc """
  Is `facts` within the authorized `accounts`? Non-account-bearing facts are
  always allowed. An empty `accounts` denies any account-bearing fact (no
  validated scope → no account data).
  """
  def within?(facts, accounts) when is_map(facts) and is_list(accounts) do
    case facts["account_reference"] do
      ref when is_binary(ref) and ref != "" -> ref in accounts
      _ -> true
    end
  end

  def within?(_facts, _accounts), do: true

  @doc """
  Is an account-keyed request (e.g. invoice) for an authorized account? Strict:
  with no validated scope (`[]`) it's denied — account data needs a scope.
  """
  def account_allowed?(account, accounts) when is_list(accounts), do: account in accounts
  def account_allowed?(_account, _accounts), do: false
end
