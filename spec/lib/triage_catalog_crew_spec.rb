# spec/lib/triage_catalog_crew_spec.rb
require "rails_helper"
require Rails.root.join("lib/signature_crew")
require Rails.root.join("lib/triage_catalog_crew")

# Semente do módulo 15 (spec 2026-10-05 §10): três protocolos pelo ciclo
# assinado, avó e neto no mesmo celular, idoso restrito a dois bairros em
# Curitiba. Idempotente.
RSpec.describe TriageCatalogCrew do
  let!(:city_record) { register_test_city! }

  before do
    create_default_protocol!
    %w[Centro Batel Portão].each { |name| Neighborhood.create!(name: name, source: "seed") }
    staff_with("admin@curitiba.demo", "municipal_admin")
    SignatureCrew.seed_current_city(slug: "curitiba", password: "dev-password")
  end
  after { Rails.cache.clear }

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41")

  it "ativa os três protocolos assinados, restringe o idoso e cria a família" do
    result = seed
    expect(result[:protocols]).to eq(%w[saude-mental-aprofundada saude-do-idoso saude-mental])
    %w[saude-mental-aprofundada saude-do-idoso saude-mental].each do |name|
      record = ProtocolDefinition.find_by!(name: name, version: 1)
      expect(record.status).to eq("active")
      expect(ProtocolSignature.where(protocol_definition: record).pluck(:purpose).tally)
        .to eq("publication" => 2, "activation" => 2)
      expect(Protocols::Gate.call(record.definition)).to be_valid
    end
    expect(result[:restricted_neighborhoods]).to eq(%w[Batel Centro])
    expect(TriageOffer.find_by!(protocol_name: "saude-do-idoso").restriction)
      .to eq("in" => [ "citizen.neighborhood_id", Neighborhood.where(name: %w[Batel Centro]).order(:name).pluck(:id) ])

    family = Citizen.where(phone: "+5541944440001").to_a
    avo = family.find { |c| c.age.to_i >= 60 }
    neto = family.find { |c| c.age.to_i < 18 }
    expect([ avo.age, neto.age ]).to eq([ 62, 8 ])
    expect(Triages::Offer.for(citizen: avo).map(&:protocol_name)).to include("saude-do-idoso")
    expect(Triages::Offer.for(citizen: neto).map(&:protocol_name)).not_to include("saude-do-idoso", "saude-mental")
  end

  it "rodar de novo não duplica nada" do
    seed
    expect { seed }.not_to change { [ ProtocolDefinition.count, Citizen.count, TriageOffer.count ] }
  end
end
