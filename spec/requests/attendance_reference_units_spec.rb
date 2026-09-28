require "rails_helper"

RSpec.describe "Unidade de referência no desfecho", type: :request do
  def body = JSON.parse(response.body)

  let(:verifier) { staff_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let!(:unit) { create_unit("UBS Centro") }
  let!(:upa) { create_unit("UPA Norte", kind: "upa") }
  let!(:ubs_sul) { create_unit("UBS Sul") }
  let!(:fechada) { create_unit("UBS Antiga", active: false) }
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let!(:batel) { Neighborhood.create!(name: "Batel", source: "seed") }

  # "UBS Centro" (a própria unidade da fila) também cobre o Centro: nunca volta.
  before do
    [ upa, unit, ubs_sul, fechada ].each { |u| NeighborhoodCoverage.create!(neighborhood: centro, health_unit: u) }
    NeighborhoodCoverage.create!(neighborhood: batel, health_unit: upa)
  end

  it "cada linha traz as unidades ativas do bairro copiado na triagem, por nome, sem a própria unidade" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432", neighborhood: centro)
    waiting = waiting_attendance(citizen, unit: unit, by: verifier)
    Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: batel.id) # troca depois: não muda o caso

    other = Citizen.create!(cpf: "11144477735", phone: "+5541911112222", neighborhood: centro)
    in_care!(waiting_attendance(other, unit: unit, by: verifier), by: doctor)

    sign_in_as(verifier)
    get "/attendance/units/#{unit.id}/queue"
    # Por nome ("UBS Sul" < "UPA Norte"): mesma ordenação de ids_by_neighborhood (Task 9).
    expect(body["waiting"].sole).to include("id" => waiting.id, "reference_unit_ids" => [ ubs_sul.id, upa.id ])
    expect(body["in_care"].sole["reference_unit_ids"]).to eq([ ubs_sul.id, upa.id ])
  end

  it "bairro coberto só pela própria unidade do atendimento: lista vazia" do
    so_propria = Neighborhood.create!(name: "Ahu", source: "seed")
    NeighborhoodCoverage.create!(neighborhood: so_propria, health_unit: unit)
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432", neighborhood: so_propria)
    waiting_attendance(citizen, unit: unit, by: verifier)
    sign_in_as(verifier)
    get "/attendance/units/#{unit.id}/queue"
    expect(body["waiting"].sole["reference_unit_ids"]).to eq([])
  end

  it "triagem sem bairro: lista vazia" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    waiting_attendance(citizen, unit: unit, by: verifier)
    sign_in_as(verifier)
    get "/attendance/units/#{unit.id}/queue"
    expect(body["waiting"].sole["reference_unit_ids"]).to eq([])
  end

  it "unidade desativada depois: some de reference_unit_ids" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432", neighborhood: centro)
    waiting_attendance(citizen, unit: unit, by: verifier)
    upa.update!(active: false)
    sign_in_as(verifier)
    get "/attendance/units/#{unit.id}/queue"
    expect(body["waiting"].sole["reference_unit_ids"]).to eq([ ubs_sul.id ])
  end
end
