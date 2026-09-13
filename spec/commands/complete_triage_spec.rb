require "rails_helper"

RSpec.describe CompleteTriage do
  let(:muni) { create(:municipality) }

  # Vocabulário de tier em INGLÊS de propósito: é o que db/seeds/dashboard_demo.rb
  # já usa (TIER_CYCLE = %w[low medium high]) e o que o gate antigo silenciava.
  def definition_hash
    {
      "name" => "triagem-urgencia",
      "version" => 1,
      "start_step_id" => "febre",
      "steps" => [
        { "id" => "febre", "prompt" => "Febre?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil },
          "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted",
                     "thresholds" => { "low" => 0, "high" => 5 },
                     "priority_map" => { "low" => 9, "high" => 1 } }
    }
  end

  def build_triage(definition = definition_hash)
    pd = ProtocolDefinition.create!(
      name: definition["name"], version: 1, status: "active",
      definition: definition, municipality_id: muni.id
    )
    convo = Conversation.create!(
      municipality_id: muni.id, phone: "+5511977770000", state: :consented
    )
    convo.consents.create!(
      version: Consents.current_version(muni.id),
      policy_text_sha: Consents.policy_text_sha(Consents.current_version(muni.id)),
      given_at: 1.minute.ago, channel: "whatsapp", evidence: { text: "sim" }
    )
    Triage.create!(
      conversation: convo, protocol_definition: pd, protocol_name: definition["name"],
      municipality_id: muni.id, status: :in_progress,
      current_step: "febre", answers: {}
    )
  end

  def urgent_events = DomainEvent.where(name: "triage.urgent")

  # Was an `around` opening a transaction with SET LOCAL app.municipality_id (RLS).
  # Removed in 5c-1: raising before `ex.run` (e.g. `muni`) skipped rspec-rails'
  # fixture teardown and leaked the pinned transaction into the rest of the suite.
  # The example already runs inside TEST_CITY_A's connection and its fixture transaction.
  before { Current.city = TEST_CITY_A }

  after { Current.reset }

  it "publishes triage.urgent for a priority-1 outcome whose tier is not 'alta'" do
    triage = build_triage

    expect { described_class.call(triage: triage, answer: "true") }
      .to change { urgent_events.count }.by(1)

    expect(triage.reload.tier).to eq("high")
    expect(triage.reload.priority).to eq(1)
  end

  it "does not publish triage.urgent for a low-priority outcome" do
    triage = build_triage

    expect { described_class.call(triage: triage, answer: "false") }
      .not_to change { urgent_events.count }

    expect(triage.reload.priority).to eq(9)
  end

  it "publishes triage.urgent when priority_when escalates a non-urgent tier" do
    definition = definition_hash.merge(
      "priority_when" => [{ "when" => { "eq" => ["febre", "false"] }, "priority" => 1 }]
    )
    triage = build_triage(definition)

    expect { described_class.call(triage: triage, answer: "false") }
      .to change { urgent_events.count }.by(1)

    expect(triage.reload.tier).to eq("low")
    expect(triage.reload.priority).to eq(1)
  end

  it "always publishes triage.completed on a terminal answer" do
    triage = build_triage

    expect { described_class.call(triage: triage, answer: "false") }
      .to change { DomainEvent.where(name: "triage.completed").count }.by(1)
  end
end
