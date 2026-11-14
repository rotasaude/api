require "rails_helper"

# Módulo 24c (ADR 0053; contrato §3.1, Q30, Q34): GET /field/v1/map pela borda
# do app de campo. Entrega o arquivo publicado da cidade, inteiro ou por
# intervalo, com o SHA-256 como ETag; a geração nova em curso não tira o
# publicado do ar. Sem trilha: o arquivo não tem dado de pessoa.
RSpec.describe "App de campo — GET /field/v1/map", type: :request do
  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:registered) { FieldDevices::Register.call(user: acs, name: "Celular").payload }
  let(:token) { registered.fetch(:token) }

  def map_get(params: nil, **headers) = get("/field/v1/map", params: params, headers: { "Authorization" => "Bearer #{token}" }.merge(headers))

  it "sem mapa publicado → 404 map_not_found; a sessão traz map null" do
    map_get
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "map_not_found" } ])
    FieldMap.create!(city_id: city.id, state: "building", requested_at: Time.current)
    map_get
    expect(response).to have_http_status(:not_found)
    get "/field/v1/session", headers: { "Authorization" => "Bearer #{token}" }
    expect(FieldSync::Schemas.errors("session-response-v1", json_body)).to eq([])
    expect(json_body).to include("map" => nil)
  end

  it "200 com o arquivo inteiro, application/vnd.pmtiles e o SHA-256 como ETag, sem trilha" do
    published_field_map!(city)
    events = DomainEvent.where("name LIKE 'clinical_record.%'")
    expect { map_get }.not_to change(events, :count)
    expect(response).to have_http_status(:ok)
    expect(response.headers).to include("Content-Type" => "application/vnd.pmtiles", "ETag" => %("#{field_map_sha}"),
                                        "Accept-Ranges" => "bytes", "Content-Length" => field_map_bytes.bytesize.to_s)
    # O Rails reescreve o Cache-Control; valem as duas diretivas, em qualquer ordem (Q34).
    expect(response.headers["Cache-Control"].split(", ")).to match_array(%w[private no-cache])
    expect(response.body.b).to eq(field_map_bytes)
  end

  it "Range → 206 com os bytes certos; If-None-Match → 304; intervalo impossível → 416" do
    published_field_map!(city)
    map_get("Range" => "bytes=0-6")
    expect(response).to have_http_status(:partial_content)
    expect(response.headers).to include("Content-Range" => "bytes 0-6/#{field_map_bytes.bytesize}", "Content-Length" => "7")
    expect(response.body.b).to eq("PMTiles".b)

    map_get("Range" => "bytes=-16")
    expect(response.body.b).to eq(field_map_bytes.byteslice(-16, 16))

    map_get("Range" => "bytes=100-", "If-Range" => %("#{'cd' * 32}"))
    expect(response).to have_http_status(:ok)
    expect(response.body.bytesize).to eq(field_map_bytes.bytesize)

    map_get("If-None-Match" => %("#{field_map_sha}"))
    expect(response).to have_http_status(:not_modified)
    expect(response.body).to be_empty

    map_get("Range" => "bytes=#{field_map_bytes.bytesize}-")
    expect([ response.status, json_body ]).to eq([ 416, { "error" => "range_not_satisfiable" } ])
    expect(response.headers["Content-Range"]).to eq("bytes */#{field_map_bytes.bytesize}")
  end

  # Review Focus 1: a geração nova (ou a falha dela) não tira o publicado do ar.
  it "com a linha em building ou failed, a sessão e o mapa seguem o publicado" do
    %w[building failed].each do |state|
      FieldMap.where(city_id: city.id).delete_all
      published_field_map!(city, state: state)
      get "/field/v1/session", headers: { "Authorization" => "Bearer #{token}" }
      expect(FieldSync::Schemas.errors("session-response-v1", json_body)).to eq([])
      expect(json_body.fetch("map")).to eq("version" => "2026-11-01", "size_bytes" => field_map_bytes.bytesize, "sha256" => field_map_sha)
      map_get
      expect(response).to have_http_status(:ok), state
      expect(response.headers["ETag"]).to eq(%("#{field_map_sha}"))
    end
  end

  it "a borda do app vale: sem token 401, suspenso 401 device_suspended, interruptor 403, query 422" do
    published_field_map!(city)
    get "/field/v1/map"
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "invalid_token" } ])

    map_get(params: { city: "x" })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])

    other = FieldDevices::Register.call(user: acs, name: "Tablet").payload
    other.fetch(:device).update!(revoked_at: Time.current, revoked_reason: "replaced")
    get "/field/v1/map", headers: { "Authorization" => "Bearer #{other.fetch(:token)}" }
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "device_suspended" } ])

    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    map_get
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "home_visits" } ])
  end
end
