require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.2, §9.3; Q31; Ruling A11): POST
# /field/v1/uploads. A borda da FieldAuthentication (415 json_required, 413
# payload_too_large) na rota real; envelope inválido → 422 invalid_request com
# path, nada gravado; resposta 200 { results } na forma do upload-response-v1.
# Nada de motivo, nome, CPF ou token no log.
RSpec.describe "App de campo — POST /field/v1/uploads", type: :request do
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
end
