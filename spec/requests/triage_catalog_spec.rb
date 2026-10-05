require "rails_helper"

# Contratos §4.1–§4.2 (ADR 0027): autores, revisores e admin leem; só o
# municipal_admin muda, com step-up.
RSpec.describe "Catálogo de triagens da cidade", type: :request do
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  let(:admin) do
    staff_with("admin-cat@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end

  def sign_in_admin!(stepped_up: true)
    session = sign_in_as(admin)
    session.update!(mfa_verified_at: Time.current) if stepped_up
  end

  before do
    create_default_protocol!
    active_protocol!("saude-do-idoso", offer: { "title" => "Saúde do idoso", "eligibility" => { "gte" => ["profile.age", 60] },
                                                "retake_after_days" => 365 })
  end
  after { Rails.cache.clear }

  let(:body_for_put) do
    { enabled: true, position: 1, restriction: { "gte" => ["profile.age", 65] }, available_from: nil,
      available_until: "2026-12-31" }
  end

  it "autor, revisor e admin leem; os demais, 403" do
    %w[protocol_author protocol_reviewer municipal_admin].each do |role|
      sign_in_as(staff_with("#{role}-cat@cidade.gov.br", role))
      get "/triage_catalog"
      expect(response).to have_http_status(:ok), role
    end
    sign_in_as(staff_with("viewer-cat@cidade.gov.br", "viewer"))
    get "/triage_catalog"
    expect(status_and_error).to eq([ 403, "missing_role" ])
  end

  it "lista os ativos: sem linha = configured false; contadores suprimidos" do
    sign_in_admin!
    get "/triage_catalog"
    idoso = body["offers"].find { |o| o["protocol_name"] == "saude-do-idoso" }
    expect(idoso).to eq(
      "protocol_name" => "saude-do-idoso", "title" => "Saúde do idoso", "active_version" => 1,
      "eligibility" => { "gte" => ["profile.age", 60] }, "retake_after_days" => 365, "configured" => false,
      "enabled" => nil, "position" => nil, "restriction" => nil, "available_from" => nil, "available_until" => nil,
      "counters" => { "offered" => 0, "started" => 0, "completed" => 0, "from_suggestion" => 0 }
    )
  end

  it "admin com step-up grava e recebe o item; evento só com nome e usuário" do
    sign_in_admin!
    put "/triage_catalog/saude-do-idoso", params: body_for_put, as: :json
    expect(response).to have_http_status(:ok)
    expect(body["offer"]).to include("configured" => true, "enabled" => true, "position" => 1,
                                     "restriction" => { "gte" => ["profile.age", 65] }, "available_until" => "2026-12-31")
    expect(DomainEvent.where(name: "triage_offer.changed").sole.payload)
      .to eq("protocol_name" => "saude-do-idoso", "user_id" => admin.id)

    get "/triage_catalog"
    expect(body["offers"].map { |o| o["protocol_name"] }).to eq(%w[saude-do-idoso triage-respiratoria])
  end

  it "sem step-up: 401 mfa_required; autor não muda: 403" do
    sign_in_admin!(stepped_up: false)
    put "/triage_catalog/saude-do-idoso", params: body_for_put, as: :json
    expect(status_and_error).to eq([ 401, "mfa_required" ])
    sign_in_as(staff_with("autor-cat@cidade.gov.br", "protocol_author")).update!(mfa_verified_at: Time.current)
    put "/triage_catalog/saude-do-idoso", params: body_for_put, as: :json
    expect(status_and_error).to eq([ 403, "missing_role" ])
    expect(TriageOffer.count).to eq(0)
  end

  it "erros: 404 unknown_protocol; 422 com o motivo" do
    sign_in_admin!
    put "/triage_catalog/fantasma", params: body_for_put, as: :json
    expect(status_and_error).to eq([ 404, "unknown_protocol" ])
    put "/triage_catalog/saude-do-idoso", params: body_for_put.merge(restriction: { "gte" => ["outcome.score", 1] }), as: :json
    expect(status_and_error).to eq([ 422, "invalid_restriction" ])
    put "/triage_catalog/saude-do-idoso", params: body_for_put.merge(available_from: "2027-01-01"), as: :json
    expect(status_and_error).to eq([ 422, "invalid_period" ])
    put "/triage_catalog/saude-do-idoso", params: body_for_put.merge(position: -1), as: :json
    expect(status_and_error).to eq([ 422, "invalid_position" ])
  end

  it "corpo que não é objeto: 422, nunca 500" do
    sign_in_admin!
    put "/triage_catalog/saude-do-idoso", params: [ 1, 2 ].to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
