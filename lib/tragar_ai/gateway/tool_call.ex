defmodule TragarAi.Gateway.ToolCall do
  @moduledoc "Audit record of a single AI tool invocation through the gateway."

  use Ash.Resource,
    otp_app: :tragar_ai,
    domain: TragarAi.Gateway,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "tool_calls"
    repo TragarAi.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :tool, :string,
      allow_nil?: false,
      description: "Tool name, e.g. \"track_shipment\"."

    attribute :transport, :atom,
      constraints: [one_of: [:rest, :mcp]],
      allow_nil?: false,
      description: "Which interface the call arrived through."

    attribute :client, :string, description: "Identifier of the calling API key / agent."
    attribute :arguments, :map, default: %{}

    attribute :outcome, :atom,
      constraints: [one_of: [:ok, :error]],
      default: :ok,
      allow_nil?: false

    attribute :duration_ms, :integer
    attribute :error, :string

    create_timestamp :inserted_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:tool, :transport, :client, :arguments, :outcome, :duration_ms, :error]
    end
  end
end
