require "rails_helper"

# Módulo 28 (ADR 0046; Desvio 13; contrato §16 O11): a eSB (tipo 71) chega pelo
# CNES, liga-se à única eSF/eAP ativa da unidade (D7) e fica de fora das linhas
# de cuidado. Review Focus 1: depois de importar a eSB e finalizar consulta
# `dental`, a população da eSF não muda e a eSB nunca aparece nas equipes das
# linhas de cuidado.
RSpec.describe "Equipes de saúde bucal pelo CNES" do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) do
    dental_city!
    care_city!
    cnes_city!
  end
  let(:admin) { dental_admin! }
  let!(:unit) { create_unit("UBS Jardim das Flores").tap { |u| u.update!(cnes: "0000001") } }
  let(:doctor) { care_doctor!(unit) }
  let(:dentist) { dentist!(unit) }
  let(:assistant) { auxiliary!(unit) }

  def esf_row(ine = "0000123456", name = "ESF JARDIM 1") = { ine: ine, kind: "70", cnes: "0000001", name: name, active: true }
  def esb_row = { ine: "0001234571", kind: "71", cnes: "0000001", name: "ESB JARDIM", active: true }
  def bond(user, ine) = { cnes: "0000001", ine: ine, cbo_code: user.professional.links.active.sole.cbo_code, cpf: nil,
                          cns: user.professional.cns }

  def proposals = Cnes::Proposal.for(city)[:proposals]
  def apply!(list) = Cnes::Apply.call(city: city, proposal_ids: list.map { |p| p[:id] }, by: admin).payload
  def esf = HealthTeam.find_by!(ine: "0000123456")
  def esb = HealthTeam.find_by!(ine: "0001234571")

  # Retrato com a eSF (médico) e a eSB (dentista e ASB) da mesma UBS; duas
  # rodadas, como o admin: as equipes e, depois, os membros.
  def import!(teams: [ esf_row, esb_row ], establishments: [])
    cnes_snapshot!(establishments: [ { cnes: "0000001", name: "UBS JARDIM DAS FLORES", unit_type: "02" } ] + establishments, teams: teams,
                   bonds: [ bond(doctor, "0000123456"), bond(dentist, "0001234571"), bond(assistant, "0001234571") ])
    team_proposals = proposals.select { |p| p[:kind] == "team" && p[:action] == "create" }
    # A eSB primeiro no pedido: o Apply ordena as 70/76 antes das 71.
    apply!(team_proposals.sort_by { |p| p[:target][:kind] == "71" ? 0 : 1 })
    apply!(proposals.select { |p| p[:kind] == "member" && p[:action] == "create" })
  end

  it "propõe a eSB e os membros dentista/ASB; o Apply cria a eSB associada à única eSF da unidade" do
    cnes_snapshot!(establishments: [ { cnes: "0000001", name: "UBS JARDIM DAS FLORES", unit_type: "02" } ],
                   teams: [ esf_row, esb_row ], bonds: [ bond(dentist, "0001234571") ])
    expect(proposals.select { |p| p[:kind] == "team" }.map { |p| p[:target].slice(:ine, :kind) })
      .to contain_exactly({ ine: "0000123456", kind: "70" }, { ine: "0001234571", kind: "71" })

    import!
    expect(esb).to have_attributes(kind: "71", health_unit_id: unit.id, associated_team_id: esf.id)
    expect(esf.associated_team_id).to be_nil
    expect(HealthTeamMember.active.where(health_team: esb).pluck(:professional_id, :cbo_code))
      .to contain_exactly([ dentist.professional.id, "223208" ], [ assistant.professional.id, "322430" ])
  end

  it "duas eSF ativas na unidade, ou nenhuma → associada nula" do
    vila = create_unit("UBS Vila Esperança").tap { |u| u.update!(cnes: "0000002") }
    import!(teams: [ esf_row, esf_row("0000123457", "ESF JARDIM 2"), esb_row,
                     { ine: "0001234572", kind: "71", cnes: "0000002", name: "ESB VILA", active: true } ],
            establishments: [ { cnes: "0000002", name: "UBS VILA ESPERANCA", unit_type: "02" } ])
    expect(esb.associated_team_id).to be_nil
    expect(HealthTeam.find_by!(ine: "0001234572")).to have_attributes(health_unit_id: vila.id, associated_team_id: nil)
  end

  describe "Review Focus 1: linhas de cuidado só com eSF/eAP" do
    before { import! }

    it "consulta dental do dentista da eSB depois da general do médico: a equipe continua a eSF" do
      patient = travel_to(1.month.ago) { care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor) }
      expect(CareLines::TeamPopulation.patient_teams([ patient.id ])).to eq(patient.id => esf.id)

      finalized_dental!(unit: unit, by: dentist, citizen: Citizen.find_by!(patient_id: patient.id))
      expect(CareLines::TeamPopulation.patient_teams([ patient.id ])).to eq(patient.id => esf.id)
      expect(CareLines::TeamPopulation.patient_teams).to eq(patient.id => esf.id)
      expect(CareLines::TeamPopulation.patient_teams(involving_team: esf)).to eq(patient.id => esf.id)
      expect(CareLines::TeamPopulation.members(team: esf)[:patient_ids]).to eq([ patient.id ])
    end

    it "só consulta dental, com o dentista também na eSF: a consulta não dá equipe" do
      HealthTeamMember.create!(professional: dentist.professional, health_team: esf, cbo_code: "223208", started_on: Time.zone.today - 30)
      patient = care_patient!(age: 40, sex: "male")
      finalized_dental!(unit: unit, by: dentist, citizen: Citizen.find_by!(patient_id: patient.id))
      expect(CareLines::TeamPopulation.patient_teams([ patient.id ])).to eq({})
      expect(CareLines::TeamPopulation.members(team: esf)[:patient_ids]).to eq([])
    end

    it "território: a eSB da unidade de referência não divide o bairro com a eSF" do
      citizen = care_citizen!(age: 70, sex: "female", neighborhood: care_neighborhood!(unit))
      expect(CareLines::TeamPopulation.citizen_teams([ citizen ])).to eq(citizen.id => esf.id)
      expect(CareLines::TeamPopulation.members(team: esf)[:citizen_ids]).to eq([ citizen.id ])
    end

    it "a eSB nunca aparece em CareLines::Access.visible_teams" do
      expect(CareLines::Access.visible_teams(admin).map(&:id)).to eq([ esf.id ])
      expect(CareLines::Access.visible_teams(dentist).map(&:id)).to eq([ esf.id ])
    end
  end
end

RSpec.describe "Linhas de cuidado com a eSB na unidade", type: :request do
  before do
    dental_city!
    care_city!
  end

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:esf) { care_team!(unit, doctor) }
  let!(:esb) do
    HealthTeam.create!(health_unit: unit, ine: "0001234571", kind: "71", name: "eSB Jardim", associated_team: esf).tap do |team|
      HealthTeamMember.create!(professional: doctor.professional, health_team: team, cbo_code: "225125", started_on: Time.zone.today - 30)
    end
  end

  it "team_id da eSB → 404 nas rotas da equipe e na prévia; a lista de equipes só traz a eSF" do
    sign_in_as(doctor)
    get "/care_lines/suggestions", params: { team_id: esb.id }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "/care_lines/enrollments", params: { team_id: esb.id }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "/care_lines/teams"
    expect(json_body["teams"].map { |t| t["id"] }).to eq([ esf.id ])
    get "/care_lines/suggestions", params: { team_id: esf.id }
    expect(response).to have_http_status(:ok)

    sign_in_as(staff_with("analise-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst"))
    care_lines_loaded!
    get "/care_lines/preview", params: { team_id: esb.id, indicator: "C6" }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end
end
