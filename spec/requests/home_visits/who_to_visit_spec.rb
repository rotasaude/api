require "rails_helper"

# Módulo 24b (ADR 0052; contrato §8, §13; plano, Task 18): "quem visitar" na
# rota da equipe. Quem lê a microárea (HomeVisits::Access: o ACS na sua, o
# atribuído na dele, o enfermeiro/médico em qualquer uma da equipe); lista
# nominal com trilha clinical_record.viewed (access "home_visits", os
# patient_ids da página); contagem sem trilha. Só ids e filtros na URL.
RSpec.describe "Visita domiciliar — quem visitar", type: :request do
  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { field_agent!(team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:household) { registry_household!(micro_area: area) }
  let(:today) { Time.zone.today }

  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at).map(&:payload)

  def resident!(name)
    patient = Patient.create!(cpf: valid_cpf(registry_seq!), full_name: name, mother_name: "Rita Lima",
                              birth_date: (today - 30.years).iso8601, sex: "female", race_color: "03")
    registry_registration!(patient: patient, household: household)
    patient
  end

  it "ACS lê a sua microárea: itens na ordem do nome, página com cursor e trilha com os patient_ids da página" do
    ana = resident!("Ana")
    bia = resident!("Bia")
    cris = resident!("Cris")
    sign_in_as(acs)
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id, limit: 2 }
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].map { _1["patient_id"] }).to eq([ ana.id, bia.id ])
    expect(json_body["items"].first).to eq(
      "patient_id" => ana.id, "display_name" => "Ana", "age" => 30,
      "household" => { "id" => household.id, "address_short" => "Rua das Flores, 120" }, "family_id" => nil,
      "micro_area" => { "id" => area.id, "code" => "01" }, "last_visit_on" => nil, "reasons" => [ { "code" => "never_visited" } ]
    )
    expect(trail).to eq([ { "access" => "home_visits", "micro_area_id" => area.id, "patient_ids" => [ ana.id, bia.id ],
                            "user_id" => acs.id } ])

    get "/home_visits/who_to_visit", params: { micro_area_id: area.id, limit: 2, before: json_body["next_before"] }
    expect(json_body["items"].map { _1["patient_id"] }).to eq([ cris.id ])
    expect(json_body["next_before"]).to be_nil
    expect(trail.last).to include("patient_ids" => [ cris.id ])

    get "/home_visits/who_to_visit", params: { micro_area_id: area.id, reason: [ "registration_due" ] }
    expect(json_body).to eq("items" => [], "next_before" => nil)
    expect(trail.size).to eq(2) # página vazia não grava
  end

  it "count sem trilha: { care_line, registration_due, never_visited, people }" do
    resident!("Ana")
    resident!("Bia")
    sign_in_as(acs)
    get "/home_visits/who_to_visit/count", params: { micro_area_id: area.id }
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("care_line" => 0, "registration_due" => 0, "never_visited" => 2, "people" => 2)
    expect(trail).to be_empty
  end

  it "ACS de outra microárea → 403 out_of_scope; enfermeiro da equipe lê; equipe alheia → 403; microárea desconhecida → 404" do
    patient = resident!("Ana")
    sign_in_as(field_agent!(team: team))
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    get "/home_visits/who_to_visit/count", params: { micro_area_id: area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])

    sign_in_as(nurse)
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].map { _1["patient_id"] }).to eq([ patient.id ])

    sign_in_as(registry_nurse!(care_unit!))
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])

    sign_in_as(nurse)
    get "/home_visits/who_to_visit", params: { micro_area_id: SecureRandom.uuid }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    expect(trail.size).to eq(1)
  end

  it "recusas da query: limit 101 → 422 invalid_limit; reason desconhecido → invalid_request; cursor inválido → invalid_cursor" do
    sign_in_as(acs)
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id, limit: 101 }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_limit" } ])
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id, limit: 0 }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_limit" } ])
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id, reason: [ "overdue" ] }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id, reason: "never_visited" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id, before: "xyz" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id, cpf: "12345678909" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/home_visits/who_to_visit/count", params: { micro_area_id: area.id, limit: 10 }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/home_visits/who_to_visit", params: { micro_area_id: "01" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "micro_area_id" } ])
    expect(trail).to be_empty
  end

  it "/home_visits/who_to_visit não cai no show (rotas :id só com UUID)" do
    expect(Rails.application.routes.recognize_path("/home_visits/who_to_visit", method: :get))
      .to eq(controller: "home_visits/who_to_visit", action: "index")
    expect(Rails.application.routes.recognize_path("/home_visits/who_to_visit/count", method: :get))
      .to eq(controller: "home_visits/who_to_visit", action: "count")
    sign_in_as(acs)
    get "/home_visits/who_to_visit"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "micro_area_id" } ])
  end

  it "home_visits desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(acs)
    get "/home_visits/who_to_visit", params: { micro_area_id: area.id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
  end
end
