require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe Admin::CityDetailQuery do
  self.use_transactional_tests = false

  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  def definition_for(name, version)
    {
      "name" => name, "version" => version, "start_step_id" => "s1",
      "steps" => [
        { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  before do
    allow(Rails.cache).to receive(:delete_matched)
    clean_admin_tables
  end
  after { clean_admin_tables }

  it "devolve recursos provisionados e KPIs com sparkline" do
    out = as_admin do
      m = Municipality.create!(name: "Alpha", slug: "alpha", uf: "SP", ibge_code: "3500105", status: "active")
      MunicipalityChannel.create!(municipality_id: m.id, phone_number_id: "PN", waba_id: "W",
                                  display_phone_number: "+5511", access_token: "t", active: true)
      ConsentTerm.create!(municipality_id: m.id, version: "v1", body: "termo", published_at: 1.day.ago)
      AlertRecipient.create!(municipality_id: m.id, channel: "email", destination: "ops@x", escalation_order: 0, active: true)
      ProtocolDefinition.create!(municipality_id: m.id, name: "dengue", version: 2, status: "active", definition: definition_for("dengue", 2))
      conv = Conversation.create!(municipality_id: m.id, phone: "+5511999", state: "greeting")
      prot = ProtocolDefinition.create!(municipality_id: m.id, name: "covid", version: 1, status: "active", definition: definition_for("covid", 1))
      Triage.create!(municipality_id: m.id, conversation_id: conv.id, protocol_definition_id: prot.id,
                     protocol_name: "covid", status: "completed", completed_at: 1.day.ago)
      Admin::CityDetailQuery.call(municipality: m, period: period)
    end

    expect(out[:city][:ibge_code]).to eq("3500105")
    expect(out[:resources][:channel]).to include(phone_number_id: "PN", active: true)
    expect(out[:resources][:consent_term]).to include(version: "v1")
    expect(out[:resources][:alert_recipients].first).to include(destination: "ops@x")
    expect(out[:resources][:protocols_active].map { |p| p[:name] }).to contain_exactly("dengue", "covid")
    done = out[:kpis].find { |k| k[:id] == "triages_done" }
    expect(done[:value]).to eq(1)
    # spark via Period#series (compartilhado): contrato = array com 1 bucket por dia
    # do período (7d → 7). A colocação por bucket é exercida em period_spec; aqui
    # garantimos o contrato e que a triagem do período aparece na série (soma == 1).
    expect(done[:spark]).to be_an(Array)
    expect(done[:spark].length).to eq(7)
    expect(done[:spark].sum).to eq(1)
  end
end
