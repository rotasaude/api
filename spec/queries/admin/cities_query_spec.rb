require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe Admin::CitiesQuery do
  # Cross-tenant precisa da conexão admin REAL (BYPASSRLS) — ver spec/support/admin_rls.
  self.use_transactional_tests = false

  def period(key = "7d")
    Admin::Api::Period.parse(key: key, from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])
  end

  def conversation_for(muni)
    Conversation.create!(municipality_id: muni.id, phone: "+55119#{rand(10_000_000)}", state: "greeting")
  end

  VALID_DEFINITION = {
    "name" => "dengue", "version" => 1, "start_step_id" => "s1",
    "steps" => [
      { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
        "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } }
    ],
    "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
  }.freeze

  def protocol_for(muni)
    ProtocolDefinition.create!(municipality_id: muni.id, name: "dengue", version: 1,
                               status: "active", definition: VALID_DEFINITION)
  end

  # Sem transactional tests, os create! commitam e disparam after_commit; o
  # invalidate_cache do ProtocolDefinition usa delete_matched (não suportado pelo
  # SolidCache em test). Stub para não poluir o teste de query.
  before do
    allow(Rails.cache).to receive(:delete_matched)
    clean_admin_tables
  end
  after { clean_admin_tables }

  it "agrega métricas por cidade, respeitando período nos volumes e estado point-in-time" do
    result = as_admin do
      a = Municipality.create!(name: "Alpha", slug: "alpha", uf: "SP", status: "active")
      b = Municipality.create!(name: "Bravo", slug: "bravo", uf: "RJ", status: "active")

      MunicipalityChannel.create!(municipality_id: a.id, phone_number_id: "PN-A", waba_id: "W-A",
                                  display_phone_number: "+5511", access_token: "t", active: true)

      conv_a = conversation_for(a)
      prot_a = protocol_for(a)
      # triagem concluída DENTRO do período
      Triage.create!(municipality_id: a.id, conversation_id: conv_a.id, protocol_definition_id: prot_a.id,
                     protocol_name: "dengue", status: "completed", completed_at: 1.day.ago)
      # triagem concluída FORA do período (não deve contar em triages_done)
      Triage.create!(municipality_id: a.id, conversation_id: conv_a.id, protocol_definition_id: prot_a.id,
                     protocol_name: "dengue", status: "completed", completed_at: 60.days.ago)
      InboundMessage.create!(municipality_id: a.id, from: "+55", kind: "text", message_id: "m1",
                             raw: "oi", created_at: 1.day.ago)

      Admin::CitiesQuery.call(period: period)
    end

    alpha = result.find { |c| c[:slug] == "alpha" }
    bravo = result.find { |c| c[:slug] == "bravo" }

    expect(result.map { |c| c[:slug] }).to eq(%w[alpha bravo]) # ordenado por name
    expect(alpha[:metrics][:triages_done]).to eq(1)            # só a do período
    expect(alpha[:metrics][:conversations_active]).to eq(1)
    expect(alpha[:metrics][:inbound]).to eq(1)
    expect(alpha[:channel]).to eq(active: true, display_phone_number: "+5511")
    expect(alpha[:last_activity_at]).to be_present
    expect(bravo[:metrics][:triages_done]).to eq(0)
    expect(bravo[:channel]).to be_nil
  end
end
