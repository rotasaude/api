# spec/lib/record_mode_crew_spec.rb
require "rails_helper"
require Rails.root.join("lib/signature_crew")
require Rails.root.join("lib/professional_crew")
require Rails.root.join("lib/record_mode_crew")

# Spec 2026-10-05 §10: IBGE real no city_profile, modo off, SIGTAP reduzida
# ativa, retrato do CNES fictício coerente com unidades e profissionais da
# semente, credencial cadsus simulada. Idempotente.
RSpec.describe RecordModeCrew do
  before do
    Current.city = TEST_CITY_A
    (CityProfile.current || CityProfile.new).update!(name: "Cidade Teste", uf: "PR", ibge_code: "4106902")
    SignatureCrew.seed_current_city(slug: "teste", password: "dev-password")
    ProfessionalCrew.seed_current_city(slug: "teste", password: "dev-password", admin: admin)
  end
  after { Current.reset }

  let(:admin) { staff_with("admin@teste.demo", "municipal_admin") }

  it "semeia SIGTAP da competência corrente, CPFs, credencial simulada e um retrato que gera propostas" do
    2.times do
      described_class.seed_platform!
      described_class.seed_current_city(slug: "teste", admin: admin)
    end

    competence = Time.zone.today.strftime("%Y%m")
    expect(TerminologyRelease.active.where(kind: "sigtap", version: competence).count).to eq(1)
    expect(Professional.all).not_to be_empty
    expect(Professional.all).to all(satisfy { |p| !p.cpf.nil? && CitizenIdentity::Cpf.normalize(p.cpf) == p.cpf })
    expect(IntegrationCredential.find_by!(kind: "cadsus").username).to eq("simulado")
    expect(CnesSnapshot.where(ibge_code: "4106902").count).to eq(1)

    proposals = Cnes::Proposal.for(TEST_CITY_A)[:proposals]
    expect(proposals.select { |p| p[:kind] == "unit" && p[:action] == "link" }.map { |p| p[:local][:name] })
      .to contain_exactly("UBS Jardim das Flores", "UBS Vila Esperança", "UPA 24h Centro")
    expect(HealthUnit.where.not(cnes: nil)).to be_empty
    city = register_test_city!
    expect(city).not_to be_nil
    expect(city.record_mode).to eq("off")
  end

  it "cpf_for gera CPF válido e estável" do
    expect(described_class.cpf_for("x")).to eq(described_class.cpf_for("x"))
    expect(CitizenIdentity::Cpf.normalize(described_class.cpf_for("x"))).to eq(described_class.cpf_for("x"))
  end
end
