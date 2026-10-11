require "rails_helper"

# Contrato §4 (spec §3–§4; Desvios 1–4): o profissional (CRM/CRO) pede um
# bloco pelo gov.br; o api troca o session_id e grava o lote na mesma
# requisição; nada de token no banco, no log ou na resposta. Review Focus 1:
# callback repetido, vencido, de outro usuário.
RSpec.describe "Pedido de números SNCR", type: :request do
  before do
    controlled_city!(mock: true)
    stub_sncr_mock!
  end

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  def body = JSON.parse(response.body)

  def start(kind = "rce", return_to: "/dashboard/minha-conta/sncr")
    post "/sncr/requests", params: { kind: kind, return_to: return_to }, as: :json
    body
  end

  def client_url_of(url) = URI.decode_www_form(URI(url).query).to_h.fetch("client_url")

  def callback(state, session_id: nil, error: nil)
    post "/sncr/oauth/callback", params: { state: state, session_id: session_id, error: error }.compact, as: :json
  end

  it "ponta a ponta: URL do login simulado, troca no servidor, lote gravado, saldo" do
    sign_in_as(doctor)
    started = start
    expect(started["authorize_url"]).to start_with("http://localhost:8092/api/v1/auth/login?")
    expect(client_url_of(started["authorize_url"])).to eq("#{CityPublicUrl.dashboard(Current.city)}sncr/callback")
    log = capture_log do
      callback(started["state"], session_id: fake_sncr.approve!(client_url_of(started["authorize_url"])))
    end
    expect(response).to have_http_status(:ok)
    expect(body).to include("kind" => "rce", "received" => 1000, "return_to" => "/dashboard/minha-conta/sncr")
    expect(SncrNumberBatch.find(body["batch_id"])).to have_attributes(user_id: doctor.id, simulated: true, month_request: 1)
    expect(log).not_to include(*fake_sncr.issued_tokens)
    expect(SignatureOauthState.where(user_id: doctor.id).pluck(:purpose, :provider)).to eq([ %w[sncr_rce sncr_simulated] ])

    get "/sncr/stock"
    expect(body).to eq("rce" => { "free" => 1000, "used" => 0, "voided" => 0, "requests_this_month" => 1 },
                       "ret" => { "free" => 0, "used" => 0, "voided" => 0, "requests_this_month" => 0 },
                       "low_threshold" => 50, "simulated" => true)
  end

  it "saldo e cota do mês do modo corrente: lotes reais não contam no simulado (FW2)" do
    sign_in_as(doctor)
    3.times { sncr_stock!(doctor, kind: "rce", count: 1, simulated: false) }
    sncr_stock!(doctor, kind: "rce", count: 1, simulated: true)
    get "/sncr/stock"
    expect(body["rce"]).to eq("free" => 1, "used" => 0, "voided" => 0, "requests_this_month" => 1)
    expect(body["simulated"]).to be(true)
    start("rce")
    expect(response).to have_http_status(:ok)
  end

  it "callback repetido, vencido, de outro usuário, recusado no gov.br (Review Focus 1)" do
    sign_in_as(doctor)
    started = start
    url = client_url_of(started["authorize_url"])
    callback(started["state"], session_id: fake_sncr.approve!(url))
    expect(response).to have_http_status(:ok)
    callback(started["state"], session_id: fake_sncr.approve!(url))
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_state" ])

    late = start
    session_id = fake_sncr.approve!(url)
    fake_sncr.clock = -> { Time.now + 31 }
    callback(late["state"], session_id: session_id)
    expect([ response.status, body["error"], body["return_to"] ]).to eq([ 409, "authorization_expired", "/dashboard/minha-conta/sncr" ])
    fake_sncr.clock = -> { Time.now }

    denied = start
    callback(denied["state"], error: "access_denied")
    expect([ response.status, body["error"] ]).to eq([ 403, "authorization_denied" ])

    other = start
    sign_in_as(doctor!(unit))
    callback(other["state"], session_id: fake_sncr.approve!(url))
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_state" ])
    expect(SncrNumberBatch.count).to eq(1)
    expect(SignatureOauthState.where(purpose: %w[sncr_rce sncr_ret]).pluck(:code_verifier)).to all(be_present)
  end

  it "limite do mês antes do gov.br; o SNCR recusando também; esgotamento; inscrição divergente; queda" do
    sign_in_as(doctor)
    3.times { sncr_stock!(doctor, kind: "ret", count: 1) }
    start("ret")
    expect([ response.status, body["error"] ]).to eq([ 409, "monthly_limit_reached" ])

    url = client_url_of(start["authorize_url"])
    fake_sncr.exhausted_ufs << doctor.professional.council_state
    callback(start["state"], session_id: fake_sncr.approve!(url))
    expect([ response.status, body["error"] ]).to eq([ 503, "sncr_exhausted" ])
    fake_sncr.exhausted_ufs.clear

    fake_sncr.mismatch_documents << doctor.professional.registration_number
    callback(start["state"], session_id: fake_sncr.approve!(url))
    expect([ response.status, body["error"] ]).to eq([ 403, "registration_mismatch" ])
    fake_sncr.mismatch_documents.clear

    fake_sncr.failures << 502
    callback(start["state"], session_id: fake_sncr.approve!(url))
    expect([ response.status, body["error"] ]).to eq([ 503, "sncr_unavailable" ])
    expect(SncrNumberBatch.where(kind: "rce").count).to eq(0)
  end

  it "o SNCR recusando por limite no 4º pedido: 409 com return_to, sem lote e sem session_id no log" do
    sign_in_as(doctor)
    states = Array.new(4) { start }
    url = client_url_of(states.first["authorize_url"])
    states.first(3).each do |started|
      callback(started["state"], session_id: fake_sncr.approve!(url))
      expect(response).to have_http_status(:ok)
    end
    session_id = fake_sncr.approve!(url)
    log = capture_log { callback(states.last["state"], session_id: session_id) }
    expect([ response.status, body["error"], body["return_to"] ]).to eq([ 409, "monthly_limit_reached", "/dashboard/minha-conta/sncr" ])
    expect(SncrNumberBatch.where(user_id: doctor.id, kind: "rce").count).to eq(3)
    expect(log).not_to include(session_id)
  end

  it "enfermeiro, recepção, tipo inválido, interruptor desligado" do
    sign_in_as(nurse!(unit))
    start
    expect([ response.status, body["error"] ]).to eq([ 403, "cbo_not_allowed" ])
    get "/sncr/stock"
    expect([ response.status, body["error"] ]).to eq([ 403, "cbo_not_allowed" ])
    sign_in_as(verifier!)
    start
    expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
    sign_in_as(doctor)
    start("nr")
    expect([ response.status, body["error"], body["field"] ]).to eq([ 422, "invalid_content", "kind" ])
    Platform::Features.set!(city: Current.city, key: "controlled_prescriptions", enabled: false, maintainer: ledi_maintainer!)
    get "/sncr/stock"
    expect([ response.status, body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "controlled_prescriptions" } ])
  end

  it "SNCR real sem credencial: 503 sncr_unavailable, sem state gravado" do
    Platform::Features.set!(city: Current.city, key: "sncr_mock", enabled: false, maintainer: ledi_maintainer!)
    allow(Sncr::Config).to receive(:credentials).and_return({})
    sign_in_as(doctor)
    start
    expect([ response.status, body["error"] ]).to eq([ 503, "sncr_unavailable" ])
    expect(SignatureOauthState.where(user_id: doctor.id).count).to eq(0)
  end
end
