require "rails_helper"

# Módulo 24b (ADR 0052; contrato §3, §5, §6, §13; Q14, Q17, Q21, Q51; plano,
# Task 12, Desvio 11): as visitas na rota da equipe. POST /home_visits pelo
# HomeVisits::Record (201; 200 no reenvio do mesmo client_uuid); detalhe com a
# observação; retirada pelo dono; "Visitas da equipe" e contagem. Leitura
# nominal com trilha (uma por resposta, só ids); contagem sem trilha.
# Registro de outro escopo por id → 404; lista de microárea ou equipe alheia →
# 403 out_of_scope; filtros repetidos só com []; nada de pessoa na query.
RSpec.describe "Visita domiciliar — visitas da equipe", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { field_agent!(team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at).map(&:payload)

  # Um instante antes de agora, ainda hoje (perto da meia-noite, 2 minutos
  # atrás cairia na folha de ontem).
  def earlier_today = [ 2.minutes.ago, Time.current.beginning_of_day ].max.change(usec: 0)

  def body(**over)
    { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "occurred_at" => Time.current.change(usec: 0).iso8601,
      "micro_area_id" => area.id, "property_type" => "1", "subject" => "none", "outcome" => 1, "reasons" => [ 1 ],
      "shared" => false }.merge(over.stringify_keys)
  end

  def record!(by: acs, **over)
    result = HomeVisits::Record.call(params: body(**over), by: by)
    raise "visita recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload[:visit]
  end

  it "ACS registra pelo celular e recebe visit + day (201); reenvio do mesmo client_uuid → 200 igual" do
    household = registry_household!(micro_area: area)
    payload = body(household_id: household.id).except("micro_area_id", "property_type")
    sign_in_as(acs)
    json_post "/home_visits", payload
    expect(response).to have_http_status(:created)
    visit = HomeVisit.sole
    expect(json_body.keys).to contain_exactly("visit", "day")
    expect(json_body["visit"]).to eq(
      "id" => visit.id, "client_uuid" => payload["client_uuid"], "day_id" => visit.home_visit_day_id,
      "occurred_at" => visit.occurred_at.iso8601, "shift" => visit.shift, "origin" => "dashboard", "property_type" => "1",
      "micro_area" => { "id" => area.id, "code" => "01" }, "out_of_area" => false,
      "household" => { "id" => household.id, "address_short" => "Rua das Flores, 120" }, "family_id" => nil, "subject" => "none",
      "patient" => nil, "outcome" => 1, "reasons" => [ 1 ], "shared" => false, "measurements" => nil, "state" => "recorded",
      "withdrawn" => nil, "recorded_by" => { "name" => acs.professional.professional_name }, "can_withdraw" => true
    )
    expect(json_body["day"]).to include("id" => visit.home_visit_day_id, "own" => true, "state" => "open", "visits_count" => 1,
                                        "ledi_export_enabled" => true)
    expect(json_body["day"]).not_to have_key("visits")
    first = json_body

    json_post "/home_visits", payload.merge("outcome" => 2, "reasons" => [])
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq(first)
    expect(HomeVisit.count).to eq(1)
  end

  it "recusas do registro: client_uuid de outro usuário → 409 client_uuid_conflict; enfermeiro → 403 cbo_not_allowed; regra → 422 com path" do
    payload = body
    sign_in_as(acs)
    json_post "/home_visits", payload
    expect(response).to have_http_status(:created)

    sign_in_as(field_agent!(team: team))
    json_post "/home_visits", payload
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "client_uuid_conflict", "path" => "client_uuid" } ])
    sign_in_as(nurse)
    json_post "/home_visits", body
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    sign_in_as(acs)
    json_post "/home_visits", body(outcome: 2)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "reasons_forbidden", "path" => "reasons" } ])
    json_post "/home_visits", body.except("team_id")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_home_visit", "path" => "team_id" } ])
    json_post "/home_visits", body(micro_area_id: registry_micro_area!(code: "02", team: team, acs: field_agent!(team: team)).id)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    expect(HomeVisit.count).to eq(1)
  end

  it "registro rápido com duplicado → 409 duplicate_suspected com candidates e trilha dos candidatos" do
    existing = registry_patient!
    typed = { "full_name" => existing.full_name, "birth_date" => existing.birth_date, "sex" => "female", "no_cpf_reason" => "3" }
    sign_in_as(acs)
    json_post "/home_visits", body(subject: "resident", new_patient: typed, reasons: [ 11 ])
    expect(response).to have_http_status(:conflict)
    expect(json_body).to include("error" => "duplicate_suspected", "path" => "new_patient")
    expect(json_body["candidates"].map { _1["patient_id"] }).to include(existing.id)
    expect(trail).to include(include("patient_id" => existing.id, "user_id" => acs.id, "access" => "home_visits"))
    expect(HomeVisit.count).to eq(0)
  end

  # Q67 (B-I1): a gravação que roda a busca de duplicados ou a checagem de
  # CPF/CNS consome o orçamento da busca de pessoa (30/min por usuário).
  it "Q67: 31ª sondagem (30 buscas + gravação com paciente novo) → 429 antes de gravar; patient_id não consome; volta depois da janela" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    typed = { "full_name" => "Benedita Alves Rocha", "birth_date" => "1951-03-08", "sex" => "female", "no_cpf_reason" => "3" }
    existing = registry_patient!
    sign_in_as(acs)
    30.times { json_post "/home_visits/people/lookup", { cpf: valid_cpf(9_991) } }
    expect(response).to have_http_status(:not_found)
    patients = Patient.count

    json_post "/home_visits", body(subject: "resident", new_patient: typed, reasons: [ 11 ])
    expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
    expect([ HomeVisit.count, HomeVisitDay.count, Patient.count ]).to eq([ 0, 0, patients ])
    expect(trail).to be_empty

    json_post "/home_visits", body(subject: "resident", patient_id: existing.id, reasons: [ 11 ])
    expect(response).to have_http_status(:created)
    travel(61.seconds) do
      json_post "/home_visits", body(subject: "resident", new_patient: typed, reasons: [ 11 ])
      expect(response).to have_http_status(:created)
    end
    expect(Patient.count).to eq(patients + 1)
  end

  it "GET /home_visits/:id mostra a observação ao dono e grava trilha; withdrawn.reason só ao dono e ao enfermeiro (Q17)" do
    patient = registry_patient!
    visit = record!(subject: "resident", patient_id: patient.id, reasons: [ 11 ], note: "cachorro bravo no quintal",
                    measurements: { "systolic" => 150, "diastolic" => 95 })
    sign_in_as(acs)
    get "/home_visits/#{visit.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => visit.id, "note" => "cachorro bravo no quintal", "can_withdraw" => true, "subject" => "resident",
                                 "measurements" => { "systolic" => 150, "diastolic" => 95 }, "reasons" => [ 11 ],
                                 "patient" => { "id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true,
                                                "cns_masked" => nil })
    expect(trail).to eq([ { "access" => "home_visits", "home_visit_ids" => [ visit.id ], "patient_ids" => [ patient.id ],
                            "user_id" => acs.id } ])

    json_post "/home_visits/#{visit.id}/withdraw", expected_state: "recorded", reason: "lançada na casa errada"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("state" => "withdrawn", "can_withdraw" => false)
    expect(json_body).not_to have_key("note")
    expect(json_body["withdrawn"]).to include("reason" => "lançada na casa errada",
                                              "by" => { "name" => acs.professional.professional_name })
    expect(json_body["withdrawn"]["at"]).to be_present
    json_post "/home_visits/#{visit.id}/withdraw", expected_state: "recorded", reason: "lançada na casa errada"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "visit_changed" } ])

    tacs = field_agent!(cbo: "322255", team: team)
    assignment!(area, tacs.professional)
    sign_in_as(tacs)
    get "/home_visits/#{visit.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["withdrawn"]).to include("reason" => nil)
    expect(response.body).not_to include("lançada na casa errada")
    json_post "/home_visits/#{visit.id}/withdraw", expected_state: "recorded", reason: "lançada na casa errada"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])

    sign_in_as(nurse)
    get "/home_visits/#{visit.id}"
    expect(json_body["withdrawn"]).to include("reason" => "lançada na casa errada")
  end

  it "withdraw: folha fechada → 409 day_closed; motivo curto → 422 path reason; corpo com chave estranha → 422" do
    visit = record!
    sign_in_as(acs)
    json_post "/home_visits/#{visit.id}/withdraw", expected_state: "recorded", reason: "curto"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    json_post "/home_visits/#{visit.id}/withdraw", expected_state: "recorded", reason: "lançada na casa errada", note: "x"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "note" } ])
    HomeVisits::CloseDay.call(visit.home_visit_day, by: acs, closed_by: "user")
    json_post "/home_visits/#{visit.id}/withdraw", expected_state: "recorded", reason: "lançada na casa errada"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "day_closed" } ])
    get "/home_visits/#{visit.id}"
    expect(json_body).to include("can_withdraw" => false, "state" => "recorded")
  end

  it "visita de outra equipe por id → 404; lista de outra microárea → 403 out_of_scope" do
    other_team = registry_team!(care_unit!)
    other_acs = field_agent!(team: other_team)
    other_area = registry_micro_area!(code: "07", team: other_team, acs: other_acs)
    foreign = record!(by: other_acs, team_id: other_team.id, micro_area_id: other_area.id)
    peer = field_agent!(team: team)
    peer_area = registry_micro_area!(code: "02", team: team, acs: peer)
    peer_visit = record!(by: peer, micro_area_id: peer_area.id)

    sign_in_as(acs)
    get "/home_visits/#{foreign.id}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "/home_visits/#{peer_visit.id}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    json_post "/home_visits/#{foreign.id}/withdraw", expected_state: "recorded", reason: "lançada na casa errada"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "/home_visits/#{SecureRandom.uuid}"
    expect(response).to have_http_status(:not_found)

    get "/home_visits", params: { team_id: team.id, micro_area_id: other_area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    get "/home_visits", params: { team_id: team.id, micro_area_id: peer_area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    get "/home_visits", params: { team_id: other_team.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    get "/home_visits/count", params: { team_id: team.id, micro_area_id: peer_area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    expect(trail).to be_empty

    get "/home_visits", params: { team_id: team.id }
    expect(json_body["items"]).to eq([])
    expect(trail).to be_empty
    sign_in_as(nurse)
    get "/home_visits", params: { team_id: team.id }
    expect(json_body["items"].map { _1["id"] }).to eq([ peer_visit.id ])
  end

  it "count devolve done/refused/absent/withdrawn sem trilha" do
    record!
    record!(outcome: 2, reasons: [])
    record!(outcome: 3, reasons: [])
    HomeVisits::Withdraw.call(record!, by: acs, expected_state: "recorded", reason: "lançada na casa errada")
    sign_in_as(nurse)
    get "/home_visits/count", params: { team_id: team.id }
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("done" => 1, "refused" => 1, "absent" => 1, "withdrawn" => 1)
    get "/home_visits/count", params: { team_id: team.id, micro_area_id: area.id, from: today.iso8601, to: today.iso8601 }
    expect(json_body).to eq("done" => 1, "refused" => 1, "absent" => 1, "withdrawn" => 1)
    get "/home_visits/count", params: { team_id: team.id, from: (today + 1).iso8601 }
    expect(json_body).to eq("done" => 0, "refused" => 0, "absent" => 0, "withdrawn" => 0)
    sign_in_as(acs)
    get "/home_visits/count", params: { team_id: team.id, micro_area_id: area.id }
    expect(json_body).to eq("done" => 1, "refused" => 1, "absent" => 1, "withdrawn" => 1)
    expect(trail).to be_empty
  end

  it "filtro outcome[]=2 funciona e outcome=2 sem [] → 422; a lista não traz a observação e grava uma trilha com os ids" do
    patient = registry_patient!
    record!(note: "portão azul", occurred_at: earlier_today.iso8601)
    refused = record!(outcome: 2, reasons: [], subject: "resident", patient_id: patient.id, note: "portão azul")
    sign_in_as(nurse)
    get "/home_visits?team_id=#{team.id}&outcome[]=2"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].map { _1["id"] }).to eq([ refused.id ])
    expect(json_body["items"].sole).not_to have_key("note")
    expect(response.body).not_to include("portão azul")
    expect(trail).to eq([ { "access" => "home_visits", "home_visit_ids" => [ refused.id ], "patient_ids" => [ patient.id ],
                            "user_id" => nurse.id } ])

    get "/home_visits?team_id=#{team.id}&outcome=2"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "outcome" } ])
    get "/home_visits?team_id=#{team.id}&outcome[]=9"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "outcome" } ])
    get "/home_visits?team_id=#{team.id}&outcome[]=1&outcome[]=2"
    expect(json_body["items"].size).to eq(2)

    get "/home_visits", params: { team_id: team.id, limit: 1 }
    expect(json_body["items"].map { _1["id"] }).to eq([ refused.id ])
    get "/home_visits", params: { team_id: team.id, limit: 1, before: json_body["next_before"] }
    expect(json_body["items"].size).to eq(1)
    expect(json_body["next_before"]).to be_nil
    get "/home_visits", params: { team_id: team.id, before: "xyz" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
    get "/home_visits", params: { team_id: team.id, professional_id: acs.professional.id, from: today.iso8601, to: today.iso8601 }
    expect(json_body["items"].size).to eq(2)
  end

  it "nome ou CPF na query → 422 invalid_request" do
    patient = registry_patient!
    sign_in_as(nurse)
    get "/home_visits", params: { team_id: team.id, cpf: patient.cpf }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/home_visits/count", params: { team_id: team.id, name: patient.full_name }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    sign_in_as(acs)
    get "/home_visits/days/today", params: { team_id: team.id, name: patient.full_name }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    post "/home_visits?cpf=#{patient.cpf}", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    expect(HomeVisit.count).to eq(0)
    expect(trail).to be_empty
  end
end
