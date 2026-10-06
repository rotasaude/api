# spec/services/cnes/proposal_spec.rb
require "rails_helper"

# ADR 0028 (spec 2026-10-05 §5; contratos §5.2): o retrato mais recente contra
# o cadastro da cidade. Nada é aplicado aqui — só proposto.
RSpec.describe Cnes::Proposal do
  let!(:city) { cnes_city! }
  let!(:jardim) { create_unit("UBS Jardim das Flores") }
  let!(:upa) { create_unit("UPA 24h Centro", kind: "upa") }

  def proposals = described_class.for(city)[:proposals]
  def divergences = described_class.for(city)[:divergences]
  def find(kind, action) = proposals.find { |p| p[:kind] == kind && p[:action] == action }

  it "sem retrato: snapshot nil e listas vazias" do
    CityProfile.current.update!(ibge_code: "4115200")
    expect(described_class.for(city)).to eq(snapshot: nil, proposals: [], divergences: [])
  end

  it "unidade: liga por nome (provável), cria a que tem equipe (exata), aponta a unidade sem CNES" do
    cnes_snapshot!(establishments: [ { cnes: "0000001", name: "UBS JARDIM DAS FLORES", unit_type: "02" },
                                     { cnes: "0000002", name: "UBS VILA ESPERANCA", unit_type: "02" },
                                     { cnes: "0000004", name: "HOSPITAL PARTICULAR", unit_type: "05" } ],
                   teams: [ { ine: "0000123457", kind: "76", cnes: "0000002", name: "EAP VILA", active: true } ])

    link = find("unit", "link")
    expect(link).to include(confidence: "probable", local: { name: "UBS Jardim das Flores", cnes: nil },
                            cnes: { name: "UBS JARDIM DAS FLORES", cnes: "0000001" })
    expect(link[:target]).to eq(health_unit_id: jardim.id, cnes: "0000001")
    create = find("unit", "create")
    expect(create).to include(confidence: "exact", local: nil, cnes: { name: "UBS VILA ESPERANCA", cnes: "0000002" })
    expect(proposals.map { |p| p[:cnes][:cnes] }).not_to include("0000004")
    expect(divergences).to contain_exactly(
      { kind: "unit_without_cnes", subject: { type: "health_unit", id: upa.id, label: "UPA 24h Centro" }, detail: nil }
    )
  end

  it "equipe e membro: cria equipe da unidade casada; membro por CPF exato; encerra o que saiu do CNES" do
    jardim.update!(cnes: "0000001")
    helena = professional_with!("medica@cidade.gov.br", unit: jardim, cbo: "225125", cpf: "52998224725")
    carla = professional_with!("enfermeira@cidade.gov.br", unit: jardim, cbo: "223505", cns: "700000000000005")
    old_team = HealthTeam.create!(ine: "0000123458", kind: "70", name: "ESF JARDIM 2", health_unit: jardim)
    gone = HealthTeamMember.create!(professional: carla, health_team: old_team, cbo_code: "223505", started_on: Date.current)
    cnes_snapshot!(establishments: [ { cnes: "0000001", name: "UBS JARDIM DAS FLORES", unit_type: "02" } ],
                   teams: [ { ine: "0000123456", kind: "70", cnes: "0000001", name: "ESF JARDIM 1", active: true },
                            { ine: "0000123458", kind: "70", cnes: "0000001", name: "ESF JARDIM 2", active: false } ],
                   bonds: [ { cnes: "0000001", ine: "0000123456", cbo_code: "225125", cpf: "52998224725", cns: nil },
                            { cnes: "0000001", ine: nil, cbo_code: "225142", cpf: "52998224725", cns: nil } ])

    expect(find("team", "create")).to include(confidence: "exact", cnes: { name: "ESF JARDIM 1", cnes: "0000001", ine: "0000123456" })
    expect(find("team", "end")).to include(confidence: "exact", local: { name: "ESF JARDIM 2", ine: "0000123458" })
    expect(find("member", "end")[:target]).to eq(health_team_member_id: gone.id)
    expect(divergences.map { |d| d[:kind] }).to include("team_inactive_in_cnes", "no_bond_in_cnes", "cbo_mismatch")
    expect(divergences.find { |d| d[:kind] == "no_bond_in_cnes" }[:subject]).to include(type: "professional", id: carla.id)
    expect(divergences.find { |d| d[:kind] == "cbo_mismatch" }[:detail]).to eq("CNES informa CBO 225142; cadastro: 225125")

    HealthTeam.create!(ine: "0000123456", kind: "70", name: "ESF JARDIM 1", health_unit: jardim)
    member = find("member", "create")
    expect(member).to include(confidence: "exact",
                              local: { name: helena.professional_name, cpf_masked: "***.982.247-**", cns_masked: helena.cns_masked },
                              cnes: { name: "ESF JARDIM 1", ine: "0000123456", cbo: "225125", cpf_masked: "***.982.247-**",
                                      cns_masked: nil })
  end

  it "membro só por CNS é provável; id estável para o mesmo retrato" do
    jardim.update!(cnes: "0000001")
    HealthTeam.create!(ine: "0000123456", kind: "70", name: "ESF 1", health_unit: jardim)
    professional_with!("enfermeira@cidade.gov.br", unit: jardim, cbo: "223505", cns: "700000000000005")
    cnes_snapshot!(establishments: [ { cnes: "0000001", name: "UBS JARDIM DAS FLORES", unit_type: "02" } ],
                   teams: [ { ine: "0000123456", kind: "70", cnes: "0000001", name: "ESF 1", active: true } ],
                   bonds: [ { cnes: "0000001", ine: "0000123456", cbo_code: "223505", cpf: nil, cns: "700000000000005" } ])
    expect(find("member", "create")[:confidence]).to eq("probable")
    expect(proposals.map { |p| p[:id] }).to eq(proposals.map { |p| p[:id] })
    expect(find("member", "create")[:id]).to match(/\A\h{24}\z/)
  end

  it "o retrato mais recente vence" do
    cnes_snapshot!(competence: "202608", establishments: [ { cnes: "0000009", name: "VELHA", unit_type: "02" } ])
    cnes_snapshot!(competence: "202609", establishments: [])
    expect(described_class.for(city)[:snapshot].competence).to eq("202609")
  end
end
