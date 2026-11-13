require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.3): GET /field/v1/changes?cursor=&limit=
# pela borda da FieldAuthentication. Cada página validada contra o
# changes-response-v1 do contracts; cursor adulterado → 422 invalid_cursor;
# limit fora de 1–500 → 422 invalid_limit; o cursor é opaco e sem dado pessoal.
# Todo laço de paginação tem teto fixo (max_pages).
RSpec.describe "App de campo — GET /field/v1/changes", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  def max_pages = 12

  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:token) { FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:token) }
  let!(:household) { registry_household!(micro_area: area) }
  let!(:registration) { registry_registration!(household: household) }

  before { registry_family!(household, responsible: registration.patient) }

  # O corte de agora − 2 s: o que a spec gravou só sai depois dele.
  def changes(query = {})
    travel(3.seconds) { get("/field/v1/changes", params: query, headers: { "Authorization" => "Bearer #{token}" }) }
  end

  def refused_with(status, error)
    expect([ response.status, json_body ]).to eq([ status, { "error" => error } ])
  end

  it "resposta valida contra changes-response-v1 (toda página)" do
    changes
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(FieldSync::Schemas.errors("changes-response-v1", json_body)).to eq([])
    expect(json_body.fetch("items").map { _1.fetch("type") }).to contain_exactly("micro_area", "household", "registration")

    cursor = nil
    pages = 0
    max_pages.times do
      changes(cursor ? { cursor: cursor, limit: 1 } : { limit: 1 })
      expect(response).to have_http_status(:ok)
      expect(FieldSync::Schemas.errors("changes-response-v1", json_body)).to eq([])
      pages += 1
      cursor = json_body.fetch("next_cursor")
      break unless json_body.fetch("has_more")
    end
    expect(pages).to eq(3)
    expect(json_body.fetch("who_to_visit")).to be_a(Hash)
  end

  it "cursor adulterado → 422 invalid_cursor" do
    changes
    raw = json_body.fetch("next_cursor")
    decoded = JSON.parse(Base64.urlsafe_decode64(raw))

    [ "@@@", "#{raw}x", Base64.urlsafe_encode64(decoded.merge("scope_digest" => "nope").to_json, padding: false) ].each do |cursor|
      changes(cursor: cursor)
      refused_with(422, "invalid_cursor")
    end
  end

  it "limit 501 → 422 invalid_limit (e 0, texto, fração)" do
    %w[501 0 abc 1.5 -1].each do |limit|
      changes(limit: limit)
      refused_with(422, "invalid_limit")
    end
    changes(limit: "500")
    expect(response).to have_http_status(:ok)
  end

  it "o cursor decodificado não tem nome, CPF nem endereço" do
    changes(limit: 2)
    raw = json_body.fetch("next_cursor")
    expect(raw).to match(/\A[A-Za-z0-9_-]+\z/)
    decoded = JSON.parse(Base64.urlsafe_decode64(raw))
    expect(decoded.keys).to eq(%w[v scope_digest since after_id])
    expect(decoded).to include("v" => 1)
    # Estrutura exata (sem marcador literal contra UUID/digest): só versão, digest hex, instante ISO e UUID.
    expect(decoded.fetch("scope_digest")).to match(/\A\h{64}\z/)
    expect(Time.iso8601(decoded.fetch("since"))).to be_a(Time)
    expect(decoded.fetch("after_id")).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
  end

  it "sem Bearer → 401 invalid_token" do
    get "/field/v1/changes"
    refused_with(401, "invalid_token")
  end

  it "query fora de cursor e limit (cpf, chave desconhecida) → 422 invalid_request sem eco e sem last_used_at; cursor e limit continuam valendo" do
    device = FieldDevice.find_by!(token_digest: FieldDevice.digest(token))
    [ "cpf=52998224725", "note=Texto+reservado", "limit=5&cpf=52998224725" ].each do |query|
      get "/field/v1/changes?#{query}", headers: { "Authorization" => "Bearer #{token}" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
      expect(response.body).not_to include(query.split("=").last)
    end
    expect(device.reload.last_used_at).to be_nil

    changes(limit: "1")
    expect(response).to have_http_status(:ok)
    expect(json_body.fetch("items").size).to be <= 1
    expect(device.reload.last_used_at).to be_present
    changes(cursor: json_body["next_cursor"].to_s, limit: "500")
    expect(response).to have_http_status(:ok)
  end
end
