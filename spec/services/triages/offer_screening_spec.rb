require "rails_helper"

# ADR 0030: o protocolo de acolhimento é da escuta, nunca uma triagem do cidadão.
RSpec.describe "Acolhimento fora do catálogo de triagens" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let!(:acolhimento) do
    ProtocolDefinition.create!(name: "acolhimento", version: 1, status: "active",
                               definition: { "name" => "acolhimento", "version" => 1, "kind" => "screening",
                                             "risk_rules" => [ { "when" => { "gte" => ["vitals.systolic", 180] }, "color" => "red" } ] })
  end

  it "não é oferecido, não entra no catálogo do admin e não começa como triagem" do
    citizen = profiled_citizen!(age: 40)
    expect(Triages::Offer.for(citizen: citizen).map(&:protocol_name)).not_to include("acolhimento")
    expect(Triages::CatalogAdmin.index.map { |i| i[:protocol_name] }).not_to include("acolhimento")
    expect(ProtocolDefinition.triage_protocols).not_to include(acolhimento)
    expect(ProtocolDefinition.screening_protocols).to eq([ acolhimento ])
    started = start_for!(citizen, "acolhimento")
    expect(started).to be_failure
    expect(%i[not_offered no_protocol]).to include(started.reason)
  end
end
