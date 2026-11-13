require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.1; Q7, Q20, Q21): aparelho de campo pelo
# dashboard. Cadastrar exige step-up e vínculo ativo da Tabela 7 em equipe
# 70/76; o token (rsf_…) e o qr_payload saem uma vez, com no-store, e o banco
# só guarda o SHA-256. Revogar é final (409 device_already_revoked); o dono
# revoga sem step-up, o municipal_admin revoga com step-up. As listas trazem
# status active | inactive | revoked, com inactive calculado na leitura (Q7).
RSpec.describe "Aparelhos de campo (dashboard)", type: :request do
  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let(:colleague) { field_agent!(cbo: "322255", team: team) }
  let(:nurse) { registry_nurse!(unit, team: team) }

  def register(name = "Celular da microárea 01") = json_post("/field_devices", name: name)
  def device_events(name) = DomainEvent.where(name: "field_device.#{name}").order(:occurred_at)
  def device!(user, name: "Tablet") = FieldDevices::Register.call(user: user, name: name).payload.fetch(:device)

  it "ACS cadastra com step-up e recebe token rsf_ e qr_payload uma vez; o banco só tem o digest" do
    stepped_up!(acs)
    log = capture_log { register }
    expect(response).to have_http_status(:created)
    expect(response.headers["Cache-Control"]).to eq("no-store")

    token = json_body.fetch("token")
    expect(token).to match(/\Arsf_[A-Za-z0-9_-]{43}\z/)
    device = FieldDevice.sole
    expect(json_body.fetch("device")).to eq("id" => device.id, "name" => "Celular da microárea 01", "created_at" => device.created_at.iso8601,
                                            "last_used_at" => nil, "status" => "active", "revoked_at" => nil, "revoked_reason" => nil)
    expect(json_body.keys).to match_array(%w[device token qr_payload])

    prefix = "rotasaude-field:v1:"
    expect(json_body.fetch("qr_payload")).to start_with(prefix)
    qr = JSON.parse(Base64.urlsafe_decode64(json_body.fetch("qr_payload").delete_prefix(prefix)))
    expect(qr).to eq("host" => test_city_host, "token" => token)

    expect(device.token_digest).to eq(Digest::SHA256.hexdigest(token))
    expect(device.attributes.values.map(&:to_s)).not_to include(token)
    expect(device.user_id).to eq(acs.id)
    expect(device.professional_id).to eq(acs.professional.id)
    expect(log).not_to include(token)
    expect(device_events("registered").sole.payload).to eq("field_device_id" => device.id, "user_id" => acs.id)

    get "/field_devices"
    expect(response.body).not_to include(token)
    expect(response.body).not_to include(device.token_digest)
  end

  it "sem step-up → 401 mfa_required" do
    sign_in_as(acs)
    register
    expect(response).to have_http_status(:unauthorized)
    expect(json_body).to eq("error" => "mfa_required")
    expect(FieldDevice.count).to eq(0)
  end

  it "enfermeiro → 403 cbo_not_allowed; nome fora de 1–60 → 422 invalid_request; home_visits desligado → 403 feature_disabled" do
    stepped_up!(nurse)
    register
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "cbo_not_allowed" } ])

    stepped_up!(acs)
    register("   ")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "name" } ])
    register("a" * 61)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "name" } ])
    expect(FieldDevice.count).to eq(0)

    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    register
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "home_visits" } ])
    expect(FieldDevice.count).to eq(0)
  end

  it "4º ativo → 422 device_limit; revogado não conta" do
    stepped_up!(acs)
    3.times { |i| register("Aparelho #{i}") }
    expect(FieldDevice.active.where(user: acs).count).to eq(3)
    register("Aparelho 3")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "device_limit" } ])
    expect(FieldDevice.count).to eq(3)

    json_post "/field_devices/#{FieldDevice.first.id}/revoke", {}
    expect(response).to have_http_status(:ok)
    register("Aparelho 4")
    expect(response).to have_http_status(:created)
    expect(FieldDevice.active.where(user: acs).count).to eq(3)
  end

  it "lista sem token: os do próprio usuário, com status active | inactive | revoked (Q7)" do
    active = device!(acs, name: "Ativo")
    revoked = device!(acs, name: "Revogado")
    FieldDevices::Revoke.call(revoked, by: acs, reason: "user")
    other = device!(colleague, name: "Do colega")

    sign_in_as(acs)
    get "/field_devices"
    expect(response).to have_http_status(:ok)
    items = json_body.fetch("items")
    expect(items.map { |item| item["id"] }).to match_array([ active.id, revoked.id ])
    expect(items.map(&:keys).uniq).to eq([ %w[id name created_at last_used_at status revoked_at revoked_reason] ])
    expect(items.to_h { |item| [ item["name"], [ item["status"], item["revoked_reason"] ] ] })
      .to eq("Ativo" => [ "active", nil ], "Revogado" => [ "revoked", "user" ])
    expect(response.body).not_to include(other.id)
    expect(response.body).not_to include(active.token_digest)

    # Vínculo encerrado: ainda não revogado (só a próxima requisição do app revoga), mas inactive na leitura.
    HealthTeamMember.active.find_by!(professional: acs.professional, health_team: team).update!(ended_on: Time.zone.today)
    get "/field_devices"
    expect(json_body.fetch("items").to_h { |item| [ item["name"], item["status"] ] }).to eq("Ativo" => "inactive", "Revogado" => "revoked")
    expect(active.reload.revoked_at).to be_nil
  end

  it "revoga o próprio sem step-up; o do colega → 404; de novo → 409 device_already_revoked" do
    mine = device!(acs)
    theirs = device!(colleague)
    sign_in_as(acs)

    json_post "/field_devices/#{theirs.id}/revoke", {}
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    expect(theirs.reload.revoked_at).to be_nil

    json_post "/field_devices/#{mine.id}/revoke", {}
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("device", "status")).to eq("revoked")
    expect(mine.reload).to have_attributes(revoked_reason: "user", revoked_by_user_id: acs.id)
    expect(device_events("revoked").sole.payload).to eq("field_device_id" => mine.id, "user_id" => acs.id, "reason" => "user")

    json_post "/field_devices/#{mine.id}/revoke", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "device_already_revoked" } ])
    expect(device_events("revoked").count).to eq(1)

    post "/field_devices/#{SecureRandom.uuid}/revoke", params: "x=1", headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    expect([ response.status, json_body ]).to eq([ 415, { "error" => "json_required" } ])
    post "/field_devices/not-a-uuid/revoke", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:not_found)
  end

  it "admin lista a cidade (com user e o mesmo status, filtro user_id) e revoga com step-up" do
    mine = device!(acs, name: "Do ACS")
    theirs = device!(colleague, name: "Do TACS")
    admin = municipal_admin!

    sign_in_as(acs)
    get "/field_devices/admin"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    sign_in_as(admin)
    get "/field_devices/admin"
    expect(response).to have_http_status(:ok)
    items = json_body.fetch("items")
    expect(items.map { |item| item["id"] }).to match_array([ mine.id, theirs.id ])
    expect(items.find { |item| item["id"] == theirs.id })
      .to include("name" => "Do TACS", "status" => "active", "user" => { "id" => colleague.id, "name" => colleague.professional.professional_name })
    expect(response.body).not_to include(mine.token_digest)

    get "/field_devices/admin", params: { user_id: acs.id }
    expect(json_body.fetch("items").map { |item| item["id"] }).to eq([ mine.id ])
    get "/field_devices/admin", params: { user_id: "x" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "user_id" } ])

    json_post "/field_devices/admin/#{theirs.id}/revoke", {}
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    expect(theirs.reload.revoked_at).to be_nil

    stepped_up!(admin)
    json_post "/field_devices/admin/#{theirs.id}/revoke", {}
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("device", "status")).to eq("revoked")
    expect(theirs.reload).to have_attributes(revoked_reason: "admin", revoked_by_user_id: admin.id)
    expect(device_events("revoked").sole.payload).to eq("field_device_id" => theirs.id, "user_id" => colleague.id, "reason" => "admin")

    json_post "/field_devices/admin/#{theirs.id}/revoke", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "device_already_revoked" } ])
    json_post "/field_devices/admin/#{SecureRandom.uuid}/revoke", {}
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "query (cpf ou chave desconhecida) em /field_devices e /field_devices/admin → 422 invalid_request sem eco, nada criado nem revogado" do
    admin = municipal_admin!
    theirs = device!(acs)
    stepped_up!(admin)
    events_before = DomainEvent.where(name: %w[field_device.registered field_device.revoked]).count
    [ "cpf=52998224725", "note=Texto+reservado" ].each do |query|
      value = query.split("=").last
      get "/field_devices?#{query}"
      post "/field_devices?#{query}", params: { name: "Celular novo" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      post "/field_devices/#{theirs.id}/revoke?#{query}", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
      get "/field_devices/admin?#{query}"
      post "/field_devices/admin/#{theirs.id}/revoke?#{query}", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
      expect(response.body).not_to include(value)
    end
    expect(FieldDevice.count).to eq(1)
    expect(theirs.reload.revoked_at).to be_nil
    expect(DomainEvent.where(name: %w[field_device.registered field_device.revoked]).count).to eq(events_before)
  end

  it "cada rota de aparelho responde 422 invalid_request à query desconhecida; user_id continua valendo só no admin" do
    admin = municipal_admin!
    theirs = device!(acs)
    stepped_up!(admin)
    [ [ :get, "/field_devices?cpf=1" ], [ :post, "/field_devices?cpf=1" ], [ :post, "/field_devices/#{theirs.id}/revoke?cpf=1" ],
      [ :get, "/field_devices/admin?cpf=1" ], [ :post, "/field_devices/admin/#{theirs.id}/revoke?cpf=1" ],
      [ :get, "/field_devices?user_id=#{acs.id}" ] ].each do |verb, url|
      verb == :get ? get(url) : post(url, params: "{}", headers: { "CONTENT_TYPE" => "application/json" })
      expect([ url, response.status, json_body ]).to eq([ url, 422, { "error" => "invalid_request" } ])
    end
    get "/field_devices/admin", params: { user_id: acs.id }
    expect(response).to have_http_status(:ok)
  end
end
