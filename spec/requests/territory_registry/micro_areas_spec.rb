require "rails_helper"

# Módulo 24a (ADR 0042; contrato §3 e §14 L2): microáreas da equipe e as
# equipes 70/76 com os candidatos a ACS, só municipal_admin; escrita com
# step-up; evento micro_area.changed só com ids.
RSpec.describe "Território — microáreas", type: :request do
  before { registry_city! }

  let(:admin) { care_admin! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }

  it "cria com step-up, lista por equipe, troca o ACS e desativa; só ids no evento" do
    sign_in_as(admin)
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "01", name: "Norte", acs_professional_id: acs.professional.id
    expect(json_body).to eq("error" => "mfa_required")
    stepped_up!(admin)
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "01", name: "Norte", acs_professional_id: acs.professional.id
    expect(response).to have_http_status(:created)
    expect(json_body).to include("code" => "01", "name" => "Norte", "active" => true,
                                 "team" => { "id" => team.id, "ine" => team.ine, "name" => team.name },
                                 "acs" => { "professional_id" => acs.professional.id, "name" => acs.professional.professional_name })
    id = json_body["id"]
    json_patch "/territory/admin/micro_areas/#{id}", active: false
    expect(json_body["active"]).to be(false)
    get "/territory/admin/micro_areas", params: { team_id: team.id }
    expect(json_body["micro_areas"].map { |a| a["id"] }).to eq([ id ])
    expect(DomainEvent.where(name: "micro_area.changed").last.payload.keys).to match_array(%w[micro_area_id team_id user_id])
  end

  it "recusas: código, duplicado, ACS de fora, equipe que não é 70/76, quem não é admin" do
    stepped_up!(admin)
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "1", name: "X"
    expect(json_body).to eq("error" => "invalid_code")
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "00", name: "X"
    expect(json_body).to eq("error" => "invalid_code")
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "02", name: "X"
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "02", name: "Y"
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "duplicate_code")
    outsider = registry_acs!(care_unit!)
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "03", name: "X", acs_professional_id: outsider.professional.id
    expect(json_body).to eq("error" => "acs_not_in_team")
    nurse = registry_nurse!(unit, team: team)
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "03", name: "X", acs_professional_id: nurse.professional.id
    expect(json_body).to eq("error" => "acs_not_in_team")
    sign_in_as(nurse)
    get "/territory/admin/micro_areas", params: { team_id: team.id }
    expect(response).to have_http_status(:forbidden)
  end

  it "interruptor desligado → 403 feature_disabled" do
    Platform::Features.set!(city: City.find(Current.city.id), key: "territory_registry", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(admin)
    get "/territory/admin/micro_areas", params: { team_id: team.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "territory_registry")
    get "/territory/admin/teams"
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "territory_registry")
  end

  it "PATCH: renomeia, troca e tira o ACS, reativa; nome e active inválidos com field; ACS inválido na edição" do
    other = registry_acs!(unit, team: team)
    area = registry_micro_area!(code: "05", team: team, acs: acs)
    stepped_up!(admin)
    json_patch "/territory/admin/micro_areas/#{area.id}", name: "  Vila   Verde  ", acs_professional_id: other.professional.id
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("code" => "05", "name" => "Vila Verde",
                                 "acs" => { "professional_id" => other.professional.id, "name" => other.professional.professional_name })
    json_patch "/territory/admin/micro_areas/#{area.id}", acs_professional_id: nil
    expect(json_body["acs"]).to be_nil
    json_patch "/territory/admin/micro_areas/#{area.id}", active: false
    json_patch "/territory/admin/micro_areas/#{area.id}", active: true
    expect(json_body["active"]).to be(true)
    expect(DomainEvent.where(name: "micro_area.changed").count).to eq(4)
    json_patch "/territory/admin/micro_areas/#{area.id}", name: ""
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_micro_area", "field" => "name")
    json_patch "/territory/admin/micro_areas/#{area.id}", name: "x" * 61
    expect(json_body).to eq("error" => "invalid_micro_area", "field" => "name")
    json_patch "/territory/admin/micro_areas/#{area.id}", active: "false"
    expect(json_body).to eq("error" => "invalid_micro_area", "field" => "active")
    json_patch "/territory/admin/micro_areas/#{area.id}", acs_professional_id: registry_nurse!(unit, team: team).professional.id
    expect(json_body).to eq("error" => "acs_not_in_team")
    json_patch "/territory/admin/micro_areas/#{area.id}", acs_professional_id: "nao-e-uuid"
    expect(json_body).to eq("error" => "acs_not_in_team")
    expect(area.reload).to have_attributes(name: "Vila Verde", acs_professional_id: nil, active: true)
    expect(DomainEvent.where(name: "micro_area.changed").count).to eq(4)
  end

  it "o código e a equipe não mudam pelo PATCH (chaves fora do contrato são ignoradas)" do
    area = registry_micro_area!(code: "06", team: team)
    stepped_up!(admin)
    json_patch "/territory/admin/micro_areas/#{area.id}", code: "07", team_id: registry_team!.id, name: "Sul"
    expect(response).to have_http_status(:ok)
    expect(area.reload).to have_attributes(code: "06", team_id: team.id, name: "Sul")
  end

  it "equipe ou microárea inexistente → 404; equipe inativa não recebe microárea; nome inválido na criação" do
    stepped_up!(admin)
    get "/territory/admin/micro_areas", params: { team_id: SecureRandom.uuid }
    expect(response).to have_http_status(:not_found)
    get "/territory/admin/micro_areas"
    expect(json_body).to eq("error" => "not_found")
    json_post "/territory/admin/micro_areas", team_id: "x", code: "01", name: "Norte"
    expect(response).to have_http_status(:not_found)
    expect(json_body).to eq("error" => "not_found")
    json_patch "/territory/admin/micro_areas/#{SecureRandom.uuid}", name: "Norte"
    expect(response).to have_http_status(:not_found)
    team.update!(active: false)
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "01", name: "Norte"
    expect(response).to have_http_status(:not_found)
    team.update!(active: true)
    json_post "/territory/admin/micro_areas", team_id: team.id, code: "01", name: " "
    expect(json_body).to eq("error" => "invalid_micro_area", "field" => "name")
    json_post "/territory/admin/micro_areas", team_id: team.id, code: 1, name: "Norte"
    expect(json_body).to eq("error" => "invalid_code")
    expect(MicroArea.count).to eq(0)
  end

  it "o corpo manda: team_id, código e nome na query não valem" do
    stepped_up!(admin)
    post "/territory/admin/micro_areas?team_id=#{team.id}&code=01&name=Norte", params: {}.to_json,
                                                                                headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:not_found)
    expect(MicroArea.count).to eq(0)
  end

  it "lista em ordem de código, só da equipe pedida" do
    registry_micro_area!(code: "12", team: team)
    registry_micro_area!(code: "03", team: team)
    registry_micro_area!(code: "01", team: registry_team!(care_unit!))
    sign_in_as(admin)
    get "/territory/admin/micro_areas", params: { team_id: team.id }
    expect(json_body["micro_areas"].map { |a| a["code"] }).to eq(%w[03 12])
    expect(json_body["micro_areas"].first).to eq("id" => MicroArea.find_by!(team: team, code: "03").id,
                                                 "team" => { "id" => team.id, "ine" => team.ine, "name" => team.name },
                                                 "code" => "03", "name" => "Microárea 03", "acs" => nil, "active" => true)
  end

  describe "GET /territory/admin/teams (§14 L2)" do
    it "equipes ativas com os ACS membros (CBO 515105) e has_cns; sem outros membros nem vínculos encerrados" do
      other_unit = care_unit!
      other_team = registry_team!(other_unit)
      acs_without_cns = registry_acs!(other_unit, team: other_team)
      acs_without_cns.professional.update_columns(cns: "")
      registry_nurse!(unit, team: team)
      ended = registry_acs!(unit, team: team)
      HealthTeamMember.find_by!(professional: ended.professional, health_team: team).update!(ended_on: Time.zone.today)
      registry_team!(care_unit!).update!(active: false)
      acs # membro ACS da equipe
      sign_in_as(admin)
      get "/territory/admin/teams"
      expect(response).to have_http_status(:ok)
      teams = json_body["teams"].index_by { |t| t["id"] }
      expect(teams.keys).to contain_exactly(team.id, other_team.id)
      expect(teams[team.id]).to eq("id" => team.id, "ine" => team.ine, "name" => team.name, "kind" => "70",
                                   "unit" => { "id" => unit.id, "name" => unit.name },
                                   "acs_candidates" => [ { "professional_id" => acs.professional.id,
                                                           "name" => acs.professional.professional_name, "has_cns" => true } ])
      expect(teams[other_team.id]["acs_candidates"])
        .to eq([ { "professional_id" => acs_without_cns.professional.id, "name" => acs_without_cns.professional.professional_name,
                   "has_cns" => false } ])
    end

    it "ACS sem CNS não vira responsável (acs_without_cns)" do
      acs.professional.update_columns(cns: "")
      stepped_up!(admin)
      json_post "/territory/admin/micro_areas", team_id: team.id, code: "01", name: "Norte", acs_professional_id: acs.professional.id
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "acs_without_cns")
    end

    it "só municipal_admin" do
      sign_in_as(registry_nurse!(unit, team: team))
      get "/territory/admin/teams"
      expect(response).to have_http_status(:forbidden)
    end
  end
end
