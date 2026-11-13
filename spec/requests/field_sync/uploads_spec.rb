require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.2, §9.3; Q31; Ruling A11): POST
# /field/v1/uploads. A borda da FieldAuthentication (415 json_required, 413
# payload_too_large) na rota real; envelope inválido → 422 invalid_request com
# path, nada gravado; resposta 200 { results } na forma do upload-response-v1.
# Nada de motivo, nome, CPF ou token no log.
RSpec.describe "App de campo — POST /field/v1/uploads", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { home_visit_city! }
  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:token) { FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:token) }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def send_upload(raw, type: "application/json")
    post "/field/v1/uploads", params: raw, headers: { "Authorization" => "Bearer #{token}", "Content-Type" => type }
  end

  def item(type, body) = { "client_uuid" => SecureRandom.uuid, "type" => type, "body" => body }

  def visit_body(**over)
    { "team_id" => team.id, "occurred_at" => Time.current.change(usec: 0).iso8601, "micro_area_id" => area.id, "property_type" => "1",
      "subject" => "none", "outcome" => 1, "reasons" => [ 1 ], "shared" => false }.merge(over.stringify_keys)
  end

  it "resposta valida contra upload-response-v1" do
    cpf = valid_cpf(registry_seq!)
    items = [ item("home_visit", visit_body),
              item("home_visit", visit_body(occurred_at: (Time.current - 400.days).change(usec: 0).iso8601)),
              item("patient", { "new_patient" => { "full_name" => "Benedita Alves Rocha", "birth_date" => "1951-03-08", "sex" => "female",
                                                   "cpf" => cpf } }),
              { "client_uuid" => "nope", "type" => "home_visit", "body" => visit_body } ]
    send_upload({ items: items }.to_json)

    expect(response).to have_http_status(:ok)
    expect(FieldSync::Schemas.errors("upload-response-v1", json_body)).to eq([])
    expect(json_body.fetch("results").map { _1["status"] }).to eq(%w[accepted rejected accepted rejected])
    expect(HomeVisit.sole.origin).to eq("field_app")
  end

  # Q67 (B-I1): cada item que roda a busca de duplicados ou a checagem de
  # CPF/CNS consome o orçamento da busca de pessoa da equipe (30/min por
  # usuário, o mesmo nos dois sentidos).
  it "Q67: 10 buscas da equipe + 21 itens com paciente novo → o 21º rejected too_many_requests, fora do livro; os outros seguem; a busca vê o mesmo orçamento; o reenvio passa depois da janela" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    sign_in_as(acs)
    10.times { json_post "/home_visits/people/lookup", { cpf: valid_cpf(9_991) } }
    expect(response).to have_http_status(:not_found)

    people = Array.new(21) do |index|
      item("patient", { "new_patient" => { "full_name" => "Benedita Alves Rocha", "birth_date" => (Date.new(1951, 3, 1) + index).iso8601,
                                           "sex" => "female", "no_cpf_reason" => "3" } })
    end
    visit = item("home_visit", visit_body)
    send_upload({ items: people + [ visit ] }.to_json)
    expect(response).to have_http_status(:ok)
    expect(FieldSync::Schemas.errors("upload-response-v1", json_body)).to eq([])
    results = json_body.fetch("results")
    expect(results.first(20).map { _1["status"] }.uniq).to eq([ "accepted" ])
    expect(results[20]).to eq("client_uuid" => people[20]["client_uuid"], "status" => "rejected", "type" => "patient", "error" => "too_many_requests")
    expect(results[21]).to include("status" => "accepted", "type" => "home_visit")
    expect(FieldSyncReceipt.pluck(:client_uuid)).to match_array((people.first(20) + [ visit ]).map { _1["client_uuid"] })

    json_post "/home_visits/people/lookup", { cpf: valid_cpf(9_991) }
    expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])

    travel(61.seconds) do
      send_upload({ items: [ people[20] ] }.to_json)
      expect(json_body.fetch("results").sole).to include("status" => "accepted", "type" => "patient")
    end
    expect(FieldSyncReceipt.where(client_uuid: people[20]["client_uuid"])).to exist
  end

  it "51 itens → 422 invalid_request path items; envelope com chave desconhecida ou que não é objeto também, nada gravado" do
    items = Array.new(51) { item("home_visit", visit_body) }
    send_upload({ items: items }.to_json)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "items" } ])

    send_upload({ items: [ item("home_visit", visit_body) ], extra: 1 }.to_json)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "extra" } ])

    [ "[]", "{}", { items: [] }.to_json, { items: {} }.to_json, "{not json" ].each do |raw|
      send_upload(raw)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "items" } ])
    end
    expect(HomeVisit.count + FieldSyncReceipt.count).to eq(0)
  end

  it "corpo de 2 MB+1 → 413 payload_too_large" do
    pad = "x" * (FieldSync::Catalog::MAX_BODY_BYTES + 1 - %({"items":[],"pad":""}).bytesize)
    raw = %({"items":[],"pad":"#{pad}"})
    expect(raw.bytesize).to eq(FieldSync::Catalog::MAX_BODY_BYTES + 1)
    send_upload(raw)
    expect([ response.status, json_body ]).to eq([ 413, { "error" => "payload_too_large" } ])
  end

  it "Content-Type texto → 415 json_required" do
    send_upload({ items: [ item("home_visit", visit_body) ] }.to_json, type: "text/plain")
    expect([ response.status, json_body ]).to eq([ 415, { "error" => "json_required" } ])
    expect(HomeVisit.count).to eq(0)
  end

  it "o log não tem motivo, nome, CPF nem token" do
    cpf = valid_cpf(registry_seq!)
    visit_uuid = SecureRandom.uuid
    upload = [
      { "client_uuid" => visit_uuid, "type" => "home_visit", "body" => visit_body(note: "Portão azul, cão bravo") },
      item("patient", { "new_patient" => { "full_name" => "Benedita Alves Rocha", "birth_date" => "1951-03-08", "sex" => "female",
                                           "mother_name" => "Rosalina Alves", "cpf" => cpf } }),
      item("home_visit_withdrawal", { "visit_client_uuid" => visit_uuid, "reason" => "Registrada na casa errada" })
    ]
    log = capture_log { send_upload({ items: upload }.to_json) }

    expect(json_body.fetch("results").map { _1["status"] }).to eq(%w[accepted accepted accepted])
    expect(log).to include("/field/v1/uploads")
    [ token, cpf, "Benedita", "Rosalina", "Portão azul", "casa errada" ].each { |secret| expect(log).not_to include(secret) }
  end

  it "query (cpf ou chave desconhecida) → 422 invalid_request sem eco, nada gravado, last_used_at intacto" do
    device = FieldDevice.find_by!(token_digest: FieldDevice.digest(token))
    raw = { items: [ item("home_visit", visit_body) ] }.to_json
    [ "cpf=52998224725", "note=Texto+reservado" ].each do |query|
      post "/field/v1/uploads?#{query}", params: raw, headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
      expect(response.body).not_to include(query.split("=").last)
    end
    expect(device.reload.last_used_at).to be_nil
    expect(HomeVisit.count).to eq(0)
    expect(DomainEvent.where("name LIKE 'home_visit.%'").count).to eq(0)
  end
end
