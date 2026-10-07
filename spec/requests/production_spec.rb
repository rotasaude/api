require "rails_helper"

# Contratos §5.3. Exige ledi_export LIGADO; municipal_admin e analyst leem; só
# municipal_admin reenvia, com step-up.
RSpec.describe "Produção e-SUS", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:admin) do
    staff_with("prod-admin@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end

  before do
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record")
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  def entry!(status, competence: Ledi::Deadline.current(Time.zone.today), codes: nil)
    attrs = { uuid: "1234567-#{SecureRandom.uuid}", ficha_type: "procedimento", competence: competence,
              source_type: "synthetic", source_id: SecureRandom.uuid, ledi_version: "8.7.0",
              next_attempt_at: Time.current, status: status, last_error_codes: codes || [] }
    status == "accepted" ? attrs[:accepted_at] = Time.current : attrs[:bytes] = "x".b
    LediOutboxEntry.create!(attrs)
  end

  it "devolve o resumo da competência corrente no formato do contrato" do
    entry!("accepted")
    rejected = entry!("rejected", codes: [ { "field" => "cpfCidadao", "code" => "invalid" } ])
    sign_in_as(admin)
    get "/production"

    expect(response).to have_http_status(:ok)
    competence = Ledi::Deadline.current(Time.zone.today)
    expect(body.keys).to match_array(%w[competence deadline_on business_days_left alert counts rejections fichas fichas_total])
    expect(body["competence"]).to eq(competence)
    expect(body["deadline_on"]).to eq(Ledi::Deadline.on(competence).iso8601)
    expect(body["counts"]).to eq("accepted" => 1, "rejected" => 1, "pending" => 0, "sending" => 0, "failed" => 0)
    expect(body["fichas"].map(&:keys).uniq)
      .to eq([ %w[id ficha_type status attempts last_error_codes replaces_outbox_id created_at accepted_at] ])
    expect(body["fichas"].find { |f| f["id"] == rejected.id }.slice("last_error_codes", "replaces_outbox_id"))
      .to eq("last_error_codes" => [ { "field" => "cpfCidadao", "code" => "invalid" } ], "replaces_outbox_id" => nil)
  end

  # Review Focus 3.
  it "rejections agrupa por campo e código e nenhum payload sai" do
    2.times { entry!("rejected", codes: [ { "field" => "cnsCidadao", "code" => "not_allowed" } ]) }
    sign_in_as(admin)
    get "/production"
    expect(body["rejections"]).to eq([ { "field" => "cnsCidadao", "code" => "not_allowed", "count" => 2 } ])
    expect(response.body).not_to include("payload")
  end

  it "competência pedida, paginação de 50 e competência inválida" do
    51.times { entry!("pending", competence: "202609") }
    sign_in_as(admin)
    get "/production", params: { competence: "202609" }
    expect(body["fichas"].size).to eq(50)
    expect(body["fichas_total"]).to eq(51)
    get "/production", params: { competence: "202609", page: 2 }
    expect(body["fichas"].size).to eq(1)
    get "/production", params: { competence: "2026-09" }
    expect(status_and_error).to eq([ 422, "invalid_competence" ])
  end

  # R35: página absurda não estoura o offset; fora de 1..10_000 ela é limitada.
  it "página enorme: 200 com fichas vazias" do
    entry!("pending")
    sign_in_as(admin)
    get "/production", params: { page: "99999999999999999999" }
    expect(response).to have_http_status(:ok)
    expect(body["fichas"]).to eq([])
    expect(body["fichas_total"]).to eq(1)
  end

  it "analyst lê; viewer não; sem sessão 401" do
    sign_in_as(staff_with("analista@cidade.gov.br", "analyst"))
    get "/production"
    expect(response).to have_http_status(:ok)
    sign_in_as(staff_with("viewer@cidade.gov.br", "viewer"))
    get "/production"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    reset!
    use_test_city_host!
    get "/production"
    expect(response).to have_http_status(:unauthorized)
  end

  it "interruptor desligado: 403 feature_disabled nas duas rotas" do
    entry = entry!("rejected", codes: Ledi::ErrorCodes.transport("unknown"))
    ledi_off!(city)
    sign_in_as(admin).update!(mfa_verified_at: Time.current)
    get "/production"
    expect([ response.status, body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "ledi_export" } ])
    post "/production/fichas/#{entry.id}/resend", as: :json
    expect([ response.status, body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "ledi_export" } ])
  end

  it "reenvio: municipal_admin com step-up; 409 not_rejected; 404; analyst 403; sem step-up 401" do
    allow(Ledi::Observations).to receive(:resend_uuid_policy).and_return(:same)
    allow(DomainEvents).to receive(:publish).and_call_original
    rejected = entry!("rejected", codes: [ { "field" => "cnes", "code" => "invalid" } ])
    pending = entry!("pending")

    sign_in_as(admin)
    post "/production/fichas/#{rejected.id}/resend", as: :json
    expect(status_and_error).to eq([ 401, "mfa_required" ])

    sign_in_as(staff_with("analista2@cidade.gov.br", "analyst")).update!(mfa_verified_at: Time.current)
    post "/production/fichas/#{rejected.id}/resend", as: :json
    expect(status_and_error).to eq([ 403, "missing_role" ])

    sign_in_as(admin).update!(mfa_verified_at: Time.current)
    post "/production/fichas/#{rejected.id}/resend", as: :json
    expect(response).to have_http_status(:ok)
    expect(body.slice("id", "status", "last_error_codes"))
      .to eq("id" => rejected.id, "status" => "pending", "last_error_codes" => [])
    expect(DomainEvents).to have_received(:publish).with("ledi.ficha_resent", outbox_id: rejected.id, user_id: admin.id)
    post "/production/fichas/#{pending.id}/resend", as: :json
    expect(status_and_error).to eq([ 409, "not_rejected" ])
    post "/production/fichas/#{SecureRandom.uuid}/resend", as: :json
    expect(status_and_error).to eq([ 404, "not_found" ])
  end
end
