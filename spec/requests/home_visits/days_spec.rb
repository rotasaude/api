require "rails_helper"

# Módulo 24b (ADR 0052; contrato §2, §6, §13; Q5, Q14, Q16, Q17, Q50; plano,
# Task 12, Desvios 3 e 11): as folhas do dia na rota da equipe. O dono vê e
# fecha as suas; enfermeiro e médico leem as da equipe. A lista não tem pessoa
# nem trilha (e não consulta o banco por folha); o detalhe e o "hoje" mostram
# as visitas sem a observação, com trilha (o "hoje" só quando há pessoa). Folha
# de outro escopo por id → 404; equipe alheia → 403 out_of_scope.
RSpec.describe "Visita domiciliar — folhas do dia", type: :request do
  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { field_agent!(team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at).map(&:payload)

  # Visita pelo HomeVisits::Record (a folha nasce nele), ao imóvel por padrão.
  def record!(by: acs, at: Time.current.change(usec: 0), **over)
    params = { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "occurred_at" => at.iso8601, "micro_area_id" => area.id,
               "property_type" => "1", "subject" => "none", "outcome" => 1, "reasons" => [ 1 ], "shared" => false }
    result = HomeVisits::Record.call(params: params.merge(over.stringify_keys), by: by)
    raise "visita recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload[:visit]
  end

  def today_sheet(user = acs, **query)
    sign_in_as(user)
    get "/home_visits/days/today", params: { team_id: team.id }.merge(query)
  end

  it "days/today com visita a pessoa grava trilha; sem pessoa, não" do
    today_sheet
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("null")

    plain = record!(at: 2.minutes.ago.change(usec: 0))
    today_sheet
    expect(json_body).to include("id" => plain.home_visit_day_id, "own" => true, "state" => "open", "sequence" => 1,
                                 "visits_count" => 1, "withdrawn_count" => 0, "ledi_export_enabled" => true,
                                 "ficha" => { "status" => "open", "reasons" => [] })
    expect(json_body["visits"].map { _1["id"] }).to eq([ plain.id ])
    expect(json_body["visits"].first).to include("patient" => nil, "can_withdraw" => true)
    expect(json_body["visits"].first).not_to have_key("note")
    expect(trail).to be_empty

    patient = registry_patient!
    person = record!(subject: "resident", patient_id: patient.id, reasons: [ 11 ], note: "cachorro bravo no quintal")
    today_sheet
    expect(json_body["visits"].map { _1["id"] }).to eq([ plain.id, person.id ])
    expect(json_body["visits"].last["patient"]).to eq("id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true,
                                                     "cns_masked" => nil)
    expect(response.body).not_to include("cachorro bravo")
    expect(response.body).not_to include(patient.cpf)
    expect(trail).to eq([ { "access" => "home_visits", "home_visit_ids" => [ plain.id, person.id ], "patient_ids" => [ patient.id ],
                            "user_id" => acs.id } ])
  end

  it "days/today: enfermeiro (não registra) → 403 cbo_not_allowed; equipe alheia → 403 out_of_scope; sem team_id → 422" do
    today_sheet(nurse)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])
    sign_in_as(acs)
    get "/home_visits/days/today", params: { team_id: registry_team!(care_unit!).id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    get "/home_visits/days/today"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "team_id" } ])
  end

  it "enfermeiro lista as folhas da equipe sem pessoa e sem trilha; o ACS só as suas" do
    patient = registry_patient!
    open = record!(subject: "resident", patient_id: patient.id, reasons: [ 11 ]).home_visit_day
    closed = home_visit_day!(agent: acs, team: team, day: today - 1)
    home_visit!(day: closed, micro_area: area, occurred_at: (today - 1).in_time_zone.change(hour: 9))
    expect(HomeVisits::CloseDay.call(closed, by: acs, closed_by: "user")).to be_ok
    peer = field_agent!(team: team)
    peer_area = registry_micro_area!(code: "02", team: team, acs: peer)
    peer_day = record!(by: peer, micro_area_id: peer_area.id).home_visit_day

    sign_in_as(nurse)
    get "/home_visits/days", params: { team_id: team.id }
    expect(response).to have_http_status(:ok)
    items = json_body["items"]
    expect(items.map { _1["id"] }).to eq([ peer_day.id, closed.id, open.id ]) # mais recente primeiro (created_at, id)
    expect(items.map { _1["own"] }).to all(be(false))
    expect(items).to all(satisfy { |item| !item.key?("visits") })
    expect(items.find { _1["id"] == closed.id }).to include("state" => "closed", "closed_by" => "user",
                                                            "ficha" => { "status" => "pending", "reasons" => [] }, "blockers" => [])
    expect(json_body["next_before"]).to be_nil
    expect(response.body).not_to include(patient.display_name)
    expect(trail).to be_empty

    get "/home_visits/days?team_id=#{team.id}&state[]=closed"
    expect(json_body["items"].map { _1["id"] }).to eq([ closed.id ])
    get "/home_visits/days", params: { team_id: team.id, professional_id: acs.professional.id, from: today.iso8601, to: today.iso8601 }
    expect(json_body["items"].map { _1["id"] }).to eq([ open.id ])
    get "/home_visits/days", params: { team_id: team.id, limit: 1 }
    expect(json_body["items"].size).to eq(1)
    get "/home_visits/days", params: { team_id: team.id, limit: 1, before: json_body["next_before"] }
    expect(json_body["items"].map { _1["id"] }).to eq([ closed.id ])

    get "/home_visits/days?team_id=#{team.id}&state=closed"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state" } ])
    get "/home_visits/days", params: { team_id: team.id, from: "ontem" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "from" } ])
    get "/home_visits/days", params: { team_id: team.id, before: "xyz" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])

    sign_in_as(acs)
    get "/home_visits/days", params: { team_id: team.id }
    expect(json_body["items"].map { _1["id"] }).to contain_exactly(open.id, closed.id)
    expect(json_body["items"].map { _1["own"] }).to all(be(true))
    get "/home_visits/days", params: { team_id: team.id, professional_id: peer.professional.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    get "/home_visits/days", params: { team_id: registry_team!(care_unit!).id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    expect(trail).to be_empty
  end

  it "a lista não consulta o banco por folha (N+1 do Json.day: contagens, ficha e blockers)" do
    seq = 1
    sheets = lambda do
      agent = field_agent!(team: team)
      agent_area = registry_micro_area!(code: format("%02d", seq += 1), team: team, acs: agent)
      2.times { record!(by: agent, micro_area_id: agent_area.id, subject: "resident", patient_id: registry_patient!.id, reasons: [ 11 ]) }
      past = home_visit_day!(agent: agent, team: team, day: today - 1)
      home_visit!(day: past, micro_area: agent_area, occurred_at: (today - 1).in_time_zone.change(hour: 9))
      HomeVisits::CloseDay.call(past, by: agent, closed_by: "user")
    end
    count_queries = lambda do
      count = 0
      callback = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get "/home_visits/days", params: { team_id: team.id } }
      count
    end
    sign_in_as(nurse)
    sheets.call
    count_queries.call # aquece o que a primeira requisição carrega uma vez só (catálogo, sessão)
    one = count_queries.call
    expect(json_body["items"].size).to eq(2)
    3.times { sheets.call }
    four = count_queries.call
    expect(json_body["items"].size).to eq(8)
    expect(json_body["items"].select { _1["state"] == "open" }.map { _1["visits_count"] }).to eq([ 2, 2, 2, 2 ])
    expect(four).to eq(one)
  end

  it "blockers aparecem na folha aberta (profissional sem CNS); exportação desligada → ledi_export_enabled false (Q50)" do
    visit = record!
    acs.professional.update_columns(cns: "")
    sign_in_as(acs)
    get "/home_visits/days/#{visit.home_visit_day_id}"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("blockers" => [ { "code" => "professional_without_cns", "visit_id" => nil } ],
                                 "ledi_export_enabled" => true)

    ledi_off!(city)
    CityCatalog.reset_cache!
    get "/home_visits/days/#{visit.home_visit_day_id}"
    expect(json_body).to include("blockers" => [ { "code" => "professional_without_cns", "visit_id" => nil } ],
                                 "ledi_export_enabled" => false)
  end

  it "days/:id: o dono e o enfermeiro veem as visitas com trilha; outro ACS da equipe e folha de outra equipe → 404" do
    visit = record!
    HomeVisits::Withdraw.call(visit, by: acs, expected_state: "recorded", reason: "lançada na casa errada")
    day_id = visit.home_visit_day_id

    sign_in_as(nurse)
    get "/home_visits/days/#{day_id}"
    expect(json_body).to include("id" => day_id, "own" => false, "visits_count" => 0, "withdrawn_count" => 1)
    expect(json_body["visits"].sole).to include("id" => visit.id, "state" => "withdrawn", "can_withdraw" => false)
    expect(json_body["visits"].sole["withdrawn"]).to include("reason" => "lançada na casa errada")
    expect(trail).to eq([ { "access" => "home_visits", "home_visit_ids" => [ visit.id ], "patient_ids" => [], "user_id" => nurse.id } ])

    sign_in_as(field_agent!(team: team))
    get "/home_visits/days/#{day_id}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "/home_visits/days/#{SecureRandom.uuid}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    other_team = registry_team!(care_unit!)
    foreign = home_visit_day!(agent: field_agent!(team: other_team), team: other_team)
    sign_in_as(nurse)
    get "/home_visits/days/#{foreign.id}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "close pelo dono → 200 com ficha pending; de novo → 409 day_changed; sem expected_state → 422; de outro → 404" do
    visit = record!
    day_id = visit.home_visit_day_id
    sign_in_as(nurse)
    json_post "/home_visits/days/#{day_id}/close", expected_state: "open"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])

    sign_in_as(acs)
    json_post "/home_visits/days/#{day_id}/close", {}
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "expected_state" } ])
    json_post "/home_visits/days/#{day_id}/close", expected_state: "open", force: true
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "force" } ])
    expect(HomeVisitDay.find(day_id).state).to eq("open")

    json_post "/home_visits/days/#{day_id}/close", expected_state: "open"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => day_id, "state" => "closed", "closed_by" => "user", "own" => true, "blockers" => [],
                                 "ficha" => { "status" => "pending", "reasons" => [] }, "ledi_export_enabled" => true)
    expect(json_body).not_to have_key("visits")
    expect(LediOutboxEntry.where(source_type: "HomeVisitDay", source_id: day_id).sole.status).to eq("pending")

    json_post "/home_visits/days/#{day_id}/close", expected_state: "open"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "day_changed" } ])
    json_post "/home_visits/days/#{SecureRandom.uuid}/close", expected_state: "open"
    expect(response).to have_http_status(:not_found)
  end

  it "interruptor home_visits desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(nurse)
    get "/home_visits/days", params: { team_id: team.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "home_visits" } ])
  end
end
