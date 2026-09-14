require "rails_helper"

RSpec.describe Admin::ConversationsQuery do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  def definition
    {
      "name" => "resp", "version" => 1, "start_step_id" => "s1",
      "steps" => [
        { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  # Regressão: avg_complete_minutes faz pluck sobre triages ⋈ conversations, e
  # ambas têm created_at. Sem qualificar a coluna, o Postgres levanta
  # PG::AmbiguousColumn e o painel Conversas 500a assim que há ≥1 triagem
  # completa no período. Este teste exercita esse caminho.
  it "computes avgToCompleteMin over a completed triage without an ambiguous-column error" do
    prot = ProtocolDefinition.create!(name: "resp", version: 1, status: "active", definition: definition)
    conv = Conversation.create!(phone: "+5511999", state: "consented")
    Triage.create!(conversation_id: conv.id, protocol_definition_id: prot.id,
                   protocol_name: "resp", status: "completed",
                   created_at: 20.minutes.ago, completed_at: 10.minutes.ago)

    out = Admin::ConversationsQuery.call(period: period)

    expect(out[:avgToCompleteMin]).to be_a(Numeric)
    expect(out[:avgToCompleteMin]).to be_within(0.5).of(10.0)
  end

  it "returns nil avgToCompleteMin when there are no completed triages" do
    Conversation.create!(phone: "+5511888", state: "greeting")

    out = Admin::ConversationsQuery.call(period: period)

    expect(out[:avgToCompleteMin]).to be_nil
    expect(out[:funnel].find { |f| f[:key] == "greeting" }[:count]).to eq(1)
  end
end
