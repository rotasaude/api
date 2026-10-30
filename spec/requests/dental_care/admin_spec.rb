require "rails_helper"

# Módulo 28 (ADR 0046; contrato §16 O14): perfil do CEO, lista do TSB/ASB e a
# unidade `ceo`. Escrita só do municipal_admin, com step-up.
RSpec.describe "Saúde bucal — administração", type: :request do
  let!(:city) { dental_city! }
  let(:admin) { dental_admin! }
  let(:ceo) { create_unit("CEO Centro", kind: "ceo") }
  let(:ubs) { create_unit("UBS Centro") }

  def events(name) = DomainEvent.where(name: name).order(:occurred_at, :id).map(&:payload)
  def refusal(error, path) = { "error" => error, "path" => path, "problems" => [ { "path" => path, "error" => error } ] }
  def profile_path(unit) = "/dental/admin/ceo_profiles/#{unit.id}"

  describe "interruptor" do
    it "desligado → 403 feature_disabled (dental_care), em leitura e escrita" do
      Platform::Features.set!(city: city, key: "dental_care", enabled: false, maintainer: ledi_maintainer!)
      stepped_up!(admin)
      get "/dental/admin/ceo_profiles"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "dental_care" } ])
      json_put "/dental/admin/auxiliary_procedures", procedures: []
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "dental_care" } ])
    end
  end

  describe "perfil do CEO" do
    let(:body) { { ceo_type: "II", specialties: %w[endodontics prosthesis] } }

    it "PUT grava e publica ceo_profile.changed só com ids; GET devolve o perfil" do
      stepped_up!(admin)
      json_put profile_path(ceo), body
      expect([ response.status, json_body ]).to eq([ 200, { "health_unit" => { "id" => ceo.id, "name" => "CEO Centro", "kind" => "ceo" },
                                                           "ceo_type" => "II", "specialties" => %w[endodontics prosthesis] } ])
      expect(CeoProfile.find_by!(health_unit: ceo).updated_by_user).to eq(admin)
      expect(events("ceo_profile.changed")).to eq([ { "health_unit_id" => ceo.id, "user_id" => admin.id } ])
      get profile_path(ceo)
      expect(json_body).to include("ceo_type" => "II", "specialties" => %w[endodontics prosthesis])
    end

    it "PUT de novo substitui o perfil (um por unidade)" do
      stepped_up!(admin)
      json_put profile_path(ceo), body
      json_put profile_path(ceo), ceo_type: "III", specialties: %w[periodontics]
      expect(CeoProfile.where(health_unit: ceo).count).to eq(1)
      expect(json_body).to include("ceo_type" => "III", "specialties" => %w[periodontics])
    end

    it "GET sem perfil → ceo_type null e specialties vazio" do
      sign_in_as(admin)
      get profile_path(ceo)
      expect(json_body).to eq("health_unit" => { "id" => ceo.id, "name" => "CEO Centro", "kind" => "ceo" }, "ceo_type" => nil, "specialties" => [])
    end

    it "outro papel → 403 missing_role; sem step-up → 401 mfa_required" do
      sign_in_as(dentist!(ubs))
      json_put profile_path(ceo), body
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(step_up_enrolled!(admin))
      json_put profile_path(ceo), body
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(CeoProfile.count).to eq(0)
    end

    it "unidade ubs → 422 unit_not_ceo; id desconhecido → 404" do
      stepped_up!(admin)
      json_put profile_path(ubs), body
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "unit_not_ceo" } ])
      json_put "/dental/admin/ceo_profiles/#{SecureRandom.uuid}", body
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end

    it "ceo_type IV → 422 invalid_request em ceo_type" do
      stepped_up!(admin)
      json_put profile_path(ceo), body.merge(ceo_type: "IV")
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "ceo_type") ])
    end

    it "specialties vazio ou com chave fora → 422 com o path" do
      stepped_up!(admin)
      json_put profile_path(ceo), body.merge(specialties: [])
      expect([ response.status, json_body.fetch("path") ]).to eq([ 422, "specialties" ])
      json_put profile_path(ceo), body.merge(specialties: %w[endodontics surgery])
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "specialties[1]") ])
      expect(CeoProfile.count).to eq(0)
      expect(events("ceo_profile.changed")).to be_empty
    end

    it "form-encoded com cookie → 415" do
      stepped_up!(admin)
      put profile_path(ceo), params: body
      expect(response).to have_http_status(:unsupported_media_type)
    end
  end

  describe "lista dos perfis" do
    it "traz toda unidade ceo (com ou sem perfil), para admin e analista; outro papel → 403" do
      with_profile = ceo_unit!(type: "I", specialties: %w[stomatology])
      bare = ceo
      ubs
      sign_in_as(staff_with("analista-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst"))
      get "/dental/admin/ceo_profiles"
      profiles = json_body.fetch("profiles")
      expect(profiles.map { |p| p.dig("health_unit", "id") }).to contain_exactly(with_profile.id, bare.id)
      expect(profiles.find { |p| p.dig("health_unit", "id") == with_profile.id }).to include("ceo_type" => "I", "specialties" => %w[stomatology])
      expect(profiles.find { |p| p.dig("health_unit", "id") == bare.id }).to include("ceo_type" => nil, "specialties" => [])
      sign_in_as(dentist!(ubs))
      get "/dental/admin/ceo_profiles"
      expect(response).to have_http_status(:forbidden)
    end

    it "limit fora de 1..100 → 422 invalid_limit" do
      sign_in_as(admin)
      get "/dental/admin/ceo_profiles", params: { limit: 101 }
      expect([ response.status, json_body.fetch("error") ]).to eq([ 422, "invalid_limit" ])
    end
  end

  describe "lista do TSB/ASB" do
    it "GET traz a semente com o nome da release ativa; código fora da release → name null" do
      DentalAuxiliaryProcedure.create!(procedure_code: "9999999999", created_by_user: admin)
      sign_in_as(admin)
      get "/dental/admin/auxiliary_procedures"
      procedures = json_body.fetch("procedures")
      expect(procedures).to include({ "sigtap" => "0101020066", "name" => "APLICAÇÃO DE SELANTE (POR DENTE)" },
                                    { "sigtap" => "9999999999", "name" => nil })
      expect(procedures.size).to eq(DentalCare::Catalog::AUXILIARY_DEFAULT_PROCEDURES.size + 1)
    end

    it "PUT substitui a lista inteira, aceita o repetido uma vez e publica só ids e contagem" do
      stepped_up!(admin)
      json_put "/dental/admin/auxiliary_procedures", procedures: [ { sigtap: "0101020066" }, { sigtap: "0101020066" }, { sigtap: "0307010031" } ]
      expect(json_body).to eq("procedures" => [ { "sigtap" => "0101020066", "name" => "APLICAÇÃO DE SELANTE (POR DENTE)" },
                                                { "sigtap" => "0307010031", "name" => "RESTAURAÇÃO DE DENTE PERMANENTE ANTERIOR COM RESINA COMPOSTA" } ])
      expect(DentalAuxiliaryProcedure.pluck(:procedure_code)).to contain_exactly("0101020066", "0307010031")
      expect(events("dental.auxiliary_procedures_changed")).to eq([ { "user_id" => admin.id, "count" => 2 } ])
    end

    it "código com ponto → 422 em procedures[0].sigtap; mais de 100 → 422 em procedures; nada muda" do
      stepped_up!(admin)
      json_put "/dental/admin/auxiliary_procedures", procedures: [ { sigtap: "01.01.02.006-6" } ]
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "procedures[0].sigtap") ])
      json_put "/dental/admin/auxiliary_procedures", procedures: (1..101).map { |n| { sigtap: format("%010d", n) } }
      expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "procedures") ])
      expect(DentalAuxiliaryProcedure.count).to eq(DentalCare::Catalog::AUXILIARY_DEFAULT_PROCEDURES.size)
    end

    it "outro papel → 403 missing_role; sem step-up → 401 mfa_required" do
      sign_in_as(dentist!(ubs))
      get "/dental/admin/auxiliary_procedures"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(step_up_enrolled!(admin))
      json_put "/dental/admin/auxiliary_procedures", procedures: []
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    end
  end

  describe "unidade CEO" do
    it "POST /attendance/units com kind ceo cria a unidade" do
      stepped_up!(admin)
      json_post "/attendance/units", name: "CEO Boqueirão", kind: "ceo"
      expect(response).to have_http_status(:created)
      expect(HealthUnit.find_by!(name: "CEO Boqueirão").kind).to eq("ceo")
    end

    it "a lista das unidades traz ceo_profile só na unidade ceo (nulo sem perfil); UBS sem a chave" do
      with_profile = ceo_unit!(type: "II", specialties: %w[endodontics prosthesis])
      bare = ceo
      ubs
      sign_in_as(admin)
      %w[/attendance/units /attendance/units/all].each do |path|
        get path
        units = json_body.fetch("units").index_by { |u| u.fetch("id") }
        expect(units.fetch(with_profile.id)["ceo_profile"]).to eq("ceo_type" => "II", "specialties" => %w[endodontics prosthesis])
        expect(units.fetch(bare.id)).to have_key("ceo_profile")
        expect(units.fetch(bare.id)["ceo_profile"]).to be_nil
        expect(units.fetch(ubs.id)).not_to have_key("ceo_profile")
      end
    end

    it "trocar o tipo de ceo com perfil para outro → 409 unit_has_ceo_profile, e o perfil e o tipo ficam" do
      unit = ceo_unit!(type: "I", specialties: %w[stomatology])
      stepped_up!(admin)
      json_post "/attendance/units/#{unit.id}", name: unit.name, kind: "ubs"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "unit_has_ceo_profile" } ])
      expect(unit.reload.kind).to eq("ceo")
      expect(CeoProfile.where(health_unit: unit).count).to eq(1)
    end

    it "trocar o tipo de ceo sem perfil → 200; manter ceo com perfil e renomear → 200" do
      stepped_up!(admin)
      json_post "/attendance/units/#{ceo.id}", name: ceo.name, kind: "ubs"
      expect([ response.status, json_body.dig("unit", "kind") ]).to eq([ 200, "ubs" ])
      unit = ceo_unit!(type: "I", specialties: %w[stomatology])
      json_post "/attendance/units/#{unit.id}", name: "CEO Renomeado", kind: "ceo"
      expect([ response.status, json_body.dig("unit", "ceo_profile") ]).to eq([ 200, { "ceo_type" => "I", "specialties" => %w[stomatology] } ])
    end
  end

  # Desvio 13, D7; contrato §16 O11: a associação da eSB à eSF/eAP da unidade
  # quando o CNES não decide (zero ou várias). Leitura e escrita do admin;
  # escrita com step-up.
  describe "equipes de saúde bucal" do
    let!(:esf1) { HealthTeam.create!(health_unit: ubs, ine: "0000000070", kind: "70", name: "ESF Centro 1") }
    let!(:esf2) { HealthTeam.create!(health_unit: ubs, ine: "0000000076", kind: "76", name: "EAP Centro 2") }
    let!(:esb) { HealthTeam.create!(health_unit: ubs, ine: "0001234571", kind: "71", name: "ESB Centro") }
    let(:path) { "/dental/admin/oral_health_teams/#{esb.id}" }

    def team_ref(team) = { "id" => team.id, "ine" => team.ine, "name" => team.name }

    before do
      HealthTeam.create!(health_unit: ubs, ine: "0000000071", kind: "70", name: "ESF Inativa", active: false)
      HealthTeam.create!(health_unit: ceo, ine: "0000000072", kind: "70", name: "ESF Outra Unidade")
      HealthTeam.create!(health_unit: ubs, ine: "0001234579", kind: "71", name: "ESB Inativa", active: false)
    end

    it "GET lista as eSB ativas com a associada e as candidatas (70/76 ativas da unidade)" do
      sign_in_as(admin)
      get "/dental/admin/oral_health_teams"
      expect([ response.status, json_body ]).to eq(
        [ 200, { "teams" => [ { "id" => esb.id, "ine" => "0001234571", "name" => "ESB Centro",
                                "health_unit" => { "id" => ubs.id, "name" => "UBS Centro" }, "associated_team" => nil,
                                "candidates" => [ team_ref(esf2), team_ref(esf1) ] } ] } ]
      )
    end

    it "PUT associa (step-up), publica dental.team_association_changed só com ids e devolve a equipe" do
      stepped_up!(admin)
      json_put path, associated_team_id: esf2.id
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => esb.id, "associated_team" => team_ref(esf2))
      expect(esb.reload.associated_team_id).to eq(esf2.id)
      expect(events("dental.team_association_changed")).to eq([ { "team_id" => esb.id, "user_id" => admin.id } ])
      get "/dental/admin/oral_health_teams"
      expect(json_body["teams"].sole["associated_team"]).to eq(team_ref(esf2))
    end

    it "candidata de outra unidade, inativa, eSB, nula ou desconhecida → 422 em associated_team_id, nada gravado" do
      stepped_up!(admin)
      others = HealthTeam.where(ine: %w[0000000071 0000000072 0001234579]).pluck(:id)
      [ *others, esb.id, nil, SecureRandom.uuid, "x" ].each do |candidate|
        json_put path, associated_team_id: candidate
        expect([ response.status, json_body ]).to eq([ 422, refusal("invalid_request", "associated_team_id") ])
      end
      expect(esb.reload.associated_team_id).to be_nil
      expect(events("dental.team_association_changed")).to be_empty
    end

    it "equipe que não é eSB ativa → 404; outro papel → 403; sem step-up → 401" do
      stepped_up!(admin)
      json_put "/dental/admin/oral_health_teams/#{esf1.id}", associated_team_id: esf2.id
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      sign_in_as(staff_with("analise-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst"))
      get "/dental/admin/oral_health_teams"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(dentist!(ubs))
      json_put path, associated_team_id: esf1.id
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(step_up_enrolled!(admin))
      json_put path, associated_team_id: esf1.id
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(esb.reload.associated_team_id).to be_nil
    end
  end
end
