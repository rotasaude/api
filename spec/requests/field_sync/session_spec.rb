require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.2, §9.3; Q1, Q7, Q26): a borda do app de
# campo. Host da cidade, sem cookie, Authorization: Bearer rsf_…; ordem
# rate_limit (120/min por digest, por IP sem token) → home_visits → token. O
# vínculo é conferido em toda requisição: sem ele o aparelho é revogado agora
# (membership_ended | user_disabled) e a resposta é o 401 device_revoked
# uniforme. GET /field/v1/session na forma do session-response-v1, sem trilha.
RSpec.describe "App de campo — autenticação e GET /field/v1/session", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let!(:other_area) { registry_micro_area!(code: "02", team: team, acs: registry_acs!(unit, team: team)) }
  let(:registered) { FieldDevices::Register.call(user: acs, name: "Celular").payload }
  let(:device) { registered.fetch(:device) }
  let(:token) { registered.fetch(:token) }

  def session_get(bearer = token, **opts) = get("/field/v1/session", headers: bearer ? { "Authorization" => "Bearer #{bearer}" } : {}, **opts)
  def unauthorized_with(error)
    expect([ response.status, json_body ]).to eq([ 401, { "error" => error } ])
    expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
  end

  it "Bearer válido → sessão com microáreas do escopo, validada contra session-response-v1" do
    tacs = field_agent!(cbo: "322255", team: team)
    assigned = registry_micro_area!(code: "03", team: team)
    assignment!(assigned, tacs.professional)
    log = capture_log { session_get }

    expect(response).to have_http_status(:ok)
    expect(FieldSync::Schemas.errors("session-response-v1", json_body)).to eq([])
    expect(json_body).to include("contract" => "field-sync-v1", "user" => { "id" => acs.id, "name" => acs.professional.professional_name },
                                 "professional" => { "id" => acs.professional.id, "cbo" => "515105", "has_cns" => true },
                                 "features" => { "home_visits" => true, "collective_activities" => false, "territory_registry" => true },
                                 "min_date" => HomeVisits::Rules.min_date(Time.zone.today).iso8601)
    expect(Time.iso8601(json_body.fetch("server_time"))).to be_within(1.minute).of(Time.current)
    expect(json_body.fetch("teams")).to eq([ { "id" => team.id, "ine" => team.ine, "name" => team.name, "out_of_area_allowed" => true,
                                               "micro_areas" => [ { "id" => area.id, "code" => "01", "name" => "Microárea 01",
                                                                    "scope" => "responsible" } ] } ])
    expect(device.reload.last_used_at).to be_within(1.minute).of(Time.current)
    expect(log).not_to include(token)
    expect(DomainEvent.where("name LIKE 'clinical_record.%'").count).to eq(0)

    # Outro CBO da Tabela 7: só as atribuídas, sem fora de área.
    tacs_token = FieldDevices::Register.call(user: tacs, name: "Tablet").payload.fetch(:token)
    session_get(tacs_token)
    expect(FieldSync::Schemas.errors("session-response-v1", json_body)).to eq([])
    expect(json_body.fetch("teams")).to eq([ { "id" => team.id, "ine" => team.ine, "name" => team.name, "out_of_area_allowed" => false,
                                               "micro_areas" => [ { "id" => assigned.id, "code" => "03", "name" => "Microárea 03",
                                                                    "scope" => "assigned" } ] } ])
  end

  it "last_used_at muda no máximo uma vez por minuto" do
    session_get
    first = device.reload.last_used_at
    travel 30.seconds do
      session_get
      expect(device.reload.last_used_at).to eq(first)
    end
    travel 61.seconds do
      session_get
      expect(device.reload.last_used_at).to be > first
    end
  end

  it "sem Bearer → 401 invalid_token com WWW-Authenticate; desconhecido ou malformado também" do
    session_get(nil)
    unauthorized_with("invalid_token")
    session_get("rsf_#{SecureRandom.urlsafe_base64(32)}")
    unauthorized_with("invalid_token")
    get "/field/v1/session", headers: { "Authorization" => "Basic #{token}" }
    unauthorized_with("invalid_token")
  end

  it "revogado → 401 device_revoked" do
    FieldDevices::Revoke.call(device, by: acs, reason: "user")
    session_get
    unauthorized_with("device_revoked")
  end

  it "vínculo encerrado → revoga membership_ended e 401" do
    device
    HealthTeamMember.active.find_by!(professional: acs.professional, health_team: team).update!(ended_on: Time.zone.today)
    session_get
    unauthorized_with("device_revoked")
    expect(device.reload).to have_attributes(revoked_reason: "membership_ended", revoked_by_user_id: nil)
    expect(device.revoked_at).to be_present
    expect(DomainEvent.where(name: "field_device.revoked").sole.payload)
      .to eq("field_device_id" => device.id, "user_id" => acs.id, "reason" => "membership_ended")

    session_get
    unauthorized_with("device_revoked")
    expect(DomainEvent.where(name: "field_device.revoked").count).to eq(1)
  end

  it "sem o papel health_professional → revoga membership_ended" do
    device
    acs.memberships.active.where(role: "health_professional").find_each(&:revoke!)
    session_get
    unauthorized_with("device_revoked")
    expect(device.reload.revoked_reason).to eq("membership_ended")
  end

  it "usuário desativado → user_disabled" do
    device
    acs.deactivate!
    session_get
    unauthorized_with("device_revoked")
    expect(device.reload).to have_attributes(revoked_reason: "user_disabled", revoked_by_user_id: nil)
  end

  it "home_visits desligado → 403 feature_disabled (antes do token)" do
    token
    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    session_get
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "home_visits" } ])
    session_get(nil)
    expect(response).to have_http_status(:forbidden)
    expect(device.reload.last_used_at).to be_nil
  end

  it "121ª requisição → 429 (por token; sem token, pelo IP)" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    120.times { session_get }
    expect(response).to have_http_status(:ok)
    session_get
    expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])

    other = FieldDevices::Register.call(user: acs, name: "Outro").payload.fetch(:token)
    session_get(other)
    expect(response).to have_http_status(:ok)

    120.times { session_get(nil) }
    expect(response).to have_http_status(:unauthorized)
    session_get(nil)
    expect([ response.status, json_body ]).to eq([ 429, { "error" => "too_many_requests" } ])
  end

  it "token na query nunca é aceito e o log não tem o token" do
    log = capture_log do
      get "/field/v1/session", params: { token: token, access_token: token }
      unauthorized_with("invalid_token")
      session_get
      expect(response).to have_http_status(:ok)
    end
    expect(log).to include("/field/v1/session")
    expect(log).not_to include(token)
    expect(log).not_to include(device.token_digest)
  end

  it "sem cookie: a sessão do dashboard não autentica o app, e o app não abre Current.user" do
    sign_in_as(acs)
    session_get(nil)
    unauthorized_with("invalid_token")
    seen = nil
    allow_any_instance_of(FieldSync::V1::SessionsController).to receive(:show).and_wrap_original do |original, *args|
      seen = [ Current.user, Current.session ]
      original.call(*args)
    end
    session_get
    expect(seen).to eq([ nil, nil ])
  end

  describe "escrita (borda comum de /field/v1)" do
    before do
      stub_const("FieldSync::V1::ProbeController", Class.new(FieldSync::V1::BaseController) { def create = render(json: { ok: true }) })
    end

    def probe(body, type: "application/json", length: nil)
      headers = { "Authorization" => "Bearer #{token}", "CONTENT_TYPE" => type }
      headers["CONTENT_LENGTH"] = length.to_s if length
      # [status, corpo]: a sessão de integração do with_routing some no fim do bloco.
      with_routing do |set|
        set.draw { post "/field/v1/probe", to: "field_sync/v1/probe#create" }
        post "/field/v1/probe", params: body, headers: headers
        [ response.status, JSON.parse(response.body) ]
      end
    end

    it "JSON obrigatório (415 json_required) e corpo até 2 MB (413 payload_too_large)" do
      expect(probe("{}")).to eq([ 200, { "ok" => true } ])
      expect(probe("a=1", type: "application/x-www-form-urlencoded")).to eq([ 415, { "error" => "json_required" } ])
      expect(probe(%({"pad":"#{'x' * FieldSync::Catalog::MAX_BODY_BYTES}"}))).to eq([ 413, { "error" => "payload_too_large" } ])
      expect(device.reload.last_used_at).to be_present
    end
  end

  it "query (cpf ou chave desconhecida) → 422 invalid_request sem eco, sem last_used_at e sem trilha; sem token, token na query e revogado seguem 401" do
    device # cria o aparelho (last_used_at nil)
    [ "cpf=52998224725", "note=Texto+reservado", "token=#{token}" ].each do |query|
      get "/field/v1/session?#{query}", headers: { "Authorization" => "Bearer #{token}" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
      expect(response.body).not_to include(query.split("=").last)
    end
    expect(device.reload.last_used_at).to be_nil
    expect(DomainEvent.where("name LIKE 'clinical_record.%'").count).to eq(0)

    get "/field/v1/session?cpf=52998224725"
    unauthorized_with("invalid_token")
    get "/field/v1/session?token=#{token}"
    unauthorized_with("invalid_token")
    device.update!(revoked_at: Time.current, revoked_reason: "user")
    get "/field/v1/session?cpf=52998224725", headers: { "Authorization" => "Bearer #{token}" }
    unauthorized_with("device_revoked")
  end

  it "query num aparelho cujo vínculo acabou → 422 e o aparelho NÃO é revogado (a recusa vem antes da revogação)" do
    device
    acs.deactivate!
    get "/field/v1/session?cpf=52998224725", headers: { "Authorization" => "Bearer #{token}" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    expect(device.reload.revoked_at).to be_nil
  end
end
