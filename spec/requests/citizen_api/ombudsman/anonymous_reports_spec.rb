require "rails_helper"

# Módulo 33, Task 9 (ADR 0051; contrato §4; §16 Q1, Q8, Q13, Q20, Q21, Q29,
# Q38, Q41, Q43): a denúncia anônima sem login — a configuração pública e o
# formulário público de escrita. Ordem real das recusas (preflight F-16):
# 415 (require_json_for_writes, do CitizenAuthentication) → limites por IP
# (429 too_many_requests) → interruptor (403) → 413 → chaves (422) → teto da
# cidade (429 daily_cap_reached). Nada se liga à sessão do cidadão.
RSpec.describe "Denúncia anônima sem login", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city!(anonymous: true) }
  let(:text) { "Funcionário cobra para furar a fila do posto." }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    travel_to Time.zone.local(2026, 11, 11, 8, 0)
  end
  after { travel_back }

  def anon_post(params, ip: "127.0.0.1")
    post "/citizen/ombudsman/anonymous_reports", params: params.to_json,
                                                 headers: { "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => ip }
  end

  def cap_events = DomainEvent.where(name: "ombudsman.anonymous_cap_reached")
  def anonymous_count = OmbudsmanManifestation.where(channel: "web", identification_mode: "anonymous").count

  describe "POST /citizen/ombudsman/anonymous_reports" do
    it "grava denúncia anônima sem protocolo na resposta, sem cookie e sem o texto no log" do
      unit = caps!(name: "CAPS Vila Nova")
      log = capture_log { json_post "/citizen/ombudsman/anonymous_reports", body: "  #{text}  ", health_unit_id: unit.id }
      expect(response).to have_http_status(:created)
      expect(json_body).to eq("ok" => true)
      expect(response.headers["Set-Cookie"]).to be_nil
      expect(log).to include("CitizenApi::Ombudsman::AnonymousReportsController#create", "[FILTERED]") # controle positivo
      expect(log).not_to include("furar a fila")
      m = OmbudsmanManifestation.sole
      expect([ m.kind, m.identification_mode, m.channel, m.citizen_id, m.manifestant_name, m.created_by_user_id ])
        .to eq([ "report", "anonymous", "web", nil, nil, nil ])
      expect(m.protocol).to match(/\A2026-\d{6}\z/)
      expect([ m.body, m.referred_health_unit_id, m.state, m.received_at ]).to eq([ text, unit.id, "received", Time.current ])
      expect(m.attachments).to be_empty
      expect(DomainEvent.where(name: "ombudsman.manifestation_received").sole.payload).to eq("manifestation_id" => m.id)
      expect(cap_events).to be_empty
    end

    # Q58: a linha "Started POST … for <ip>" da denúncia anônima não guarda o
    # IP; o limite por IP segue contando (Rails.cache).
    it "a linha de requisição do log traz o caminho e [FILTERED] no lugar do IP" do
      log = capture_log { anon_post({ body: text }, ip: "10.9.8.7") }
      expect(response).to have_http_status(:created)
      started = log.lines.grep(/Started POST/).join
      expect(started).to include('"/citizen/ombudsman/anonymous_reports"', " for [FILTERED] at ") # controle positivo
      expect(log).not_to include("10.9.8.7")

      2.times { anon_post({ body: text }, ip: "10.9.8.7") }
      anon_post({ body: text }, ip: "10.9.8.7")
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body).to eq("error" => "too_many_requests")
    end

    it "com sufixo de formato (.json) a rota não casa: 404 e nada gravado (Q60)" do
      post "/citizen/ombudsman/anonymous_reports.json", params: { body: text }.to_json,
                                                        headers: { "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "10.9.8.7" }
      expect(response).to have_http_status(:not_found)
      expect(anonymous_count).to eq(0)
      anon_post({ body: text })
      expect(anonymous_count).to eq(1) # controle positivo
    end

    it "body de 20 a 4000 code points depois do strip (Q8); unidade inexistente ou inativa → 422" do
      anon_post({ body: "  #{'a' * 19}  " }, ip: "10.1.0.1")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "body")
      anon_post({ body: "é" * 4001 }, ip: "10.1.0.2")
      expect(json_body).to include("error" => "invalid_request", "path" => "body")
      anon_post({ body: 12_345 }, ip: "10.1.0.3")
      expect(json_body).to include("path" => "body")
      anon_post({ body: text, health_unit_id: create_unit("UBS Fechada", active: false).id }, ip: "10.1.1.1")
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")
      anon_post({ body: text, health_unit_id: "não-é-uuid" }, ip: "10.1.1.2")
      expect(json_body).to include("path" => "health_unit_id")
      expect(anonymous_count).to eq(0)

      anon_post({ body: "é" * 4000 }, ip: "10.1.2.1")
      expect(response).to have_http_status(:created)
      anon_post({ body: "a" * 20 }, ip: "10.1.2.2")
      expect(response).to have_http_status(:created)
      expect(anonymous_count).to eq(2)
    end

    it "quarta da hora pelo mesmo IP → 429 too_many_requests (Q43); outro IP segue" do
      3.times { json_post "/citizen/ombudsman/anonymous_reports", body: "Denúncia de teste número suficiente." }
      expect(response).to have_http_status(:created)
      json_post "/citizen/ombudsman/anonymous_reports", body: "Denúncia de teste número suficiente."
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body).to eq("error" => "too_many_requests")
      anon_post({ body: "Denúncia de teste número suficiente." }, ip: "10.0.9.9")
      expect(response).to have_http_status(:created)
      expect(anonymous_count).to eq(4)
    end

    it "décima primeira do dia pelo mesmo IP → 429 too_many_requests, mesmo espalhada pelas horas" do
      ok = 0
      4.times do |hour|
        3.times do
          anon_post({ body: "Denúncia de teste número suficiente." }, ip: "10.0.5.5")
          ok += 1 if response.status == 201
          break if ok == 10
        end
        break if ok == 10

        travel 61.minutes
      end
      expect(ok).to eq(10)
      anon_post({ body: "Denúncia de teste número suficiente." }, ip: "10.0.5.5")
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body).to eq("error" => "too_many_requests")
      expect(anonymous_count).to eq(10)
    end

    it "teto da cidade: bloqueia e avisa uma vez no dia" do
      OmbudsmanSetting.current.update!(anonymous_daily_cap: 1)
      json_post "/citizen/ombudsman/anonymous_reports", body: "Primeira denúncia do dia, dentro do teto."
      expect(response).to have_http_status(:created)
      2.times do |i|
        anon_post({ body: "Acima do teto #{i} com texto bastante" }, ip: "10.0.0.#{i + 2}")
        expect(response).to have_http_status(:too_many_requests)
        expect(json_body).to eq("error" => "daily_cap_reached")
      end
      expect(cap_events.sole.payload).to eq({})
      expect(OmbudsmanDailyRun.where(kind: "anonymous_cap").pluck(:run_on)).to eq([ Time.zone.today ])
      expect(anonymous_count).to eq(1)
      # A denúncia identificada do mesmo dia não conta no teto.
      raw_manifestation!(citizen: web_citizen!)
      expect(anonymous_count).to eq(1)
    end

    it "às 00:01 locais a contagem recomeça; o bloqueio do dia novo avisa de novo (preflight F-16)" do
      OmbudsmanSetting.current.update!(anonymous_daily_cap: 1)
      travel_to Time.zone.local(2026, 11, 11, 23, 59)
      anon_post({ body: text }, ip: "10.0.1.1")
      expect(response).to have_http_status(:created)
      anon_post({ body: text }, ip: "10.0.1.2")
      expect(json_body).to eq("error" => "daily_cap_reached")
      expect(cap_events.count).to eq(1)

      travel_to Time.zone.local(2026, 11, 12, 0, 1)
      anon_post({ body: text }, ip: "10.0.1.3")
      expect(response).to have_http_status(:created)
      anon_post({ body: text }, ip: "10.0.1.4")
      expect(json_body).to eq("error" => "daily_cap_reached")
      expect(cap_events.count).to eq(2)
      expect(OmbudsmanDailyRun.where(kind: "anonymous_cap").order(:run_on).pluck(:run_on))
        .to eq([ Date.new(2026, 11, 11), Date.new(2026, 11, 12) ])
      expect(anonymous_count).to eq(2)
    end

    it "recusas: chave a mais, corpo grande, formulário, query, interruptor desligado" do
      anon_post({ body: "Texto com mais de vinte letras.", kind: "complaint" }, ip: "10.0.2.1")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "kind")
      anon_post({ body: "Texto com mais de vinte letras.", ("k" * 200) => 1 }, ip: "10.0.2.2")
      expect(json_body).to include("error" => "invalid_request", "path" => "k" * 64)
      anon_post({ body: "a" * 17_000 }, ip: "10.0.2.3")
      expect(response).to have_http_status(:content_too_large)
      expect(json_body).to eq("error" => "payload_too_large")
      post "/citizen/ombudsman/anonymous_reports?body=#{'x' * 30}", params: { body: "Texto com mais de vinte letras." }.to_json,
                                                                    headers: { "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "10.0.2.4" }
      expect(json_body).to include("error" => "invalid_request", "path" => "body")
      post "/citizen/ombudsman/anonymous_reports", params: { body: "x" * 30 }, headers: { "REMOTE_ADDR" => "10.0.2.5" }
      expect(response).to have_http_status(:unsupported_media_type)
      expect(anonymous_count).to eq(0)

      Platform::Features.set!(city: city, key: "ombudsman_anonymous_web", enabled: false, maintainer: ledi_maintainer!)
      get "/citizen/ombudsman/public_config"
      expect(response).to have_http_status(:ok)
      expect(json_body["anonymous_web"]).to be(false)
      anon_post({ body: "Texto com mais de vinte letras." }, ip: "10.0.2.6")
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "ombudsman_anonymous_web")
      expect(anonymous_count).to eq(0)
    end

    it "o 413 vem antes da chave a mais; no limite de 16 KB o pedido segue às regras do texto" do
      anon_post({ body: "a" * 16_400, kind: "complaint" }, ip: "10.0.3.1")
      expect(response).to have_http_status(:content_too_large)
      body = { body: "a" * 16_360 }.to_json
      expect(body.bytesize).to be <= Ombudsman::Catalog::ANONYMOUS_MAX_BODY_BYTES
      post "/citizen/ombudsman/anonymous_reports", params: body,
                                                   headers: { "CONTENT_TYPE" => "application/json", "REMOTE_ADDR" => "10.0.3.2" }
      expect(json_body).to include("path" => "body") # não é 413: o limite é do pedido inteiro
    end
  end

  describe "GET /citizen/ombudsman/public_config" do
    it "anonymous_web e todas as unidades ativas por nome, CAPS inclusive (Q20); inativa fora" do
      create_unit("UBS Zeta")
      caps = caps!(name: "CAPS Alfa")
      inactive = create_unit("UBS Desativada", active: false)
      get "/citizen/ombudsman/public_config"
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to eq(%w[anonymous_web units])
      expect(json_body["anonymous_web"]).to be(true)
      expect(json_body["units"]).to eq(HealthUnit.active_units.map { |u| { "id" => u.id, "name" => u.name } })
      expect(json_body["units"]).to include({ "id" => caps.id, "name" => "CAPS Alfa" })
      expect(json_body["units"].map { |u| u["id"] }).not_to include(inactive.id)
      expect(response.headers["Set-Cookie"]).to be_nil
    end

    it "chave na query → 422 com o nome" do
      get "/citizen/ombudsman/public_config?cpf=52998224725"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
    end
  end

  # Q41: com um cookie de sessão VÁLIDO, as rotas públicas não leem, não
  # deslizam nem regravam a sessão, e a denúncia não ganha cidadão.
  it "nada se liga à sessão do cidadão (Q41)" do
    session = sign_in_citizen("+5541998765432")
    web_citizen!(cpf: "52998224725", phone: "+5541998765432")
    travel 2.hours # passou da janela do prazo deslizante: um resume gravaria
    before = session.reload.attributes.slice("updated_at", "last_seen_at", "expires_at")

    json_post "/citizen/ombudsman/anonymous_reports", body: text
    expect(response).to have_http_status(:created)
    expect(response.headers["Set-Cookie"]).to be_nil
    get "/citizen/ombudsman/public_config"
    expect(response).to have_http_status(:ok)
    expect(response.headers["Set-Cookie"]).to be_nil

    expect(OmbudsmanManifestation.sole.citizen_id).to be_nil
    expect(session.reload.attributes.slice("updated_at", "last_seen_at", "expires_at")).to eq(before)

    # Controle positivo: uma rota com sessão desliza e regrava o cookie.
    get "/citizen/ombudsman/manifestations"
    expect(response).to have_http_status(:ok)
    expect(response.headers["Set-Cookie"]).to include("citizen_session=")
    expect(session.reload.last_seen_at).not_to eq(before["last_seen_at"])
  end

  # Q1 e Q38: sem `ombudsman`, as duas rotas → 403 feature_disabled, sem
  # cascata: a denúncia fica ligada, nada é apagado, e religar a ouvidoria
  # devolve as duas sem tocar em `ombudsman_anonymous_web`.
  it "ombudsman desligado: 403 nas duas, sem cascata e sem apagar nada (Q1, Q38)" do
    anon_post({ body: text }, ip: "10.0.4.1")
    expect(response).to have_http_status(:created)

    Platform::Features.set!(city: city, key: "ombudsman", enabled: false, maintainer: ledi_maintainer!)
    expect { anon_post({ body: text }, ip: "10.0.4.2") }.not_to(change { anonymous_count })
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "ombudsman_anonymous_web")
    get "/citizen/ombudsman/public_config"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "ombudsman")
    expect(anonymous_count).to eq(1)
    expect(CityFeature.find_by(city_id: city.id, key: "ombudsman_anonymous_web").enabled).to be(true)

    Platform::Features.set!(city: city, key: "ombudsman", enabled: true, maintainer: ledi_maintainer!)
    get "/citizen/ombudsman/public_config"
    expect(json_body["anonymous_web"]).to be(true)
    anon_post({ body: text }, ip: "10.0.4.3")
    expect(response).to have_http_status(:created)
    expect(anonymous_count).to eq(2)
  end

  it "cidade sem a linha de configuração (dump): o teto usa o padrão (Q13, F-4)" do
    ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
    OmbudsmanSetting.delete_all
    ApplicationRecord.connection.execute("SET LOCAL session_replication_role = origin")
    anon_post({ body: text }, ip: "10.0.6.1")
    expect(response).to have_http_status(:created)
    expect(OmbudsmanSetting.sole.anonymous_daily_cap).to eq(50)
  end
end
