require "rails_helper"

# Módulo 33, Task 16 (ADR 0051; contrato §11; §16 Q17, Q28, Q49): o painel
# (técnico e ouvidor) e o painel por profissional (só o ouvidor, sem supressão).
RSpec.describe "Ouvidoria — painel", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let(:technician) { ombudsman_staff! }
  let(:ouvidor) { ombudsman! }
  let(:suppressed) { { "suppressed" => true } }

  around { |example| travel_to(Time.utc(2026, 11, 11, 15)) { example.run } }

  def doctor!(name)
    ubs = HealthUnit.create!(name: "UBS #{SecureRandom.hex(3)}", kind: "ubs")
    user = staff_with("medico-ouv-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional")
    link_professional!(user, ubs)
    user.professional.update!(professional_name: name)
    user.professional
  end

  describe "GET /ombudsman/dashboard" do
    before do
      6.times { manifestation!(received_at: Time.utc(2026, 5, 10, 15)) }
      2.times { manifestation!(received_at: Time.utc(2026, 5, 10, 15), kind: "praise") }
    end

    it "técnico e ouvidor leem; padrão = do começo do ano até hoje" do
      [ technician, ouvidor ].each do |user|
        sign_in_as(user)
        get "/ombudsman/dashboard"
        expect(response).to have_http_status(:ok)
        expect(json_body["period"]).to eq("from" => "2026-01-01", "to" => "2026-11-11")
        expect(json_body["by_kind"]).to include("complaint" => 6, "praise" => suppressed, "total" => suppressed)
        expect(json_body["by_subject"].last).to eq("id" => nil, "name" => nil, "unclassified" => true, "count" => 8)
        expect(json_body.keys).to eq(%w[period total by_kind by_channel by_state by_subject by_health_unit on_time_rate
                                        avg_days_to_conclude resolution_rate satisfaction])
      end
    end

    it "respeita from e to" do
      sign_in_as(technician)
      get "/ombudsman/dashboard", params: { from: "2026-06-01", to: "2026-06-30" }
      expect(json_body["period"]).to eq("from" => "2026-06-01", "to" => "2026-06-30")
      expect(json_body["by_kind"]["complaint"]).to eq(0)
    end

    it "período inválido ou invertido → 422 invalid_period; chave desconhecida na query → 422 invalid_request" do
      sign_in_as(technician)
      get "/ombudsman/dashboard", params: { from: "2026-13-01" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_period")
      get "/ombudsman/dashboard", params: { from: "2026-07-01", to: "2026-06-01" }
      expect(json_body).to eq("error" => "invalid_period")
      get "/ombudsman/dashboard", params: { q: "x" }
      expect(json_body).to include("error" => "invalid_request", "path" => "q")
    end

    it "quem não é da ouvidoria → 403; sem sessão → 401" do
      sign_in_as(responder!(department!))
      get "/ombudsman/dashboard"
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
    end

    it "sem sessão → 401" do
      get "/ombudsman/dashboard"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /ombudsman/dashboard/professionals" do
    it "só o ouvidor: por profissional referido e tipo, sem supressão, por nome" do
      zeca = doctor!("Zeca Medeiros")
      ana = doctor!("Ana Souza")
      manifestation!(received_at: Time.utc(2026, 5, 10, 15), referred_professional: zeca)
      manifestation!(received_at: Time.utc(2026, 5, 10, 15), referred_professional: ana, kind: "praise")
      manifestation!(received_at: Time.utc(2026, 5, 10, 15), referred_professional: ana)
      manifestation!(received_at: Time.utc(2026, 5, 10, 15), referred_professional: ana)
      manifestation!(received_at: Time.utc(2026, 5, 10, 15))
      manifestation!(received_at: Time.utc(2025, 5, 10, 15), referred_professional: zeca)

      sign_in_as(ouvidor)
      get "/ombudsman/dashboard/professionals"
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to eq(%w[items])
      expect(json_body["items"]).to eq(
        [ { "professional" => { "id" => ana.id, "name" => "Ana Souza" },
            "by_kind" => { "complaint" => 2, "report" => 0, "praise" => 1, "suggestion" => 0, "request" => 0 }, "total" => 3 },
          { "professional" => { "id" => zeca.id, "name" => "Zeca Medeiros" },
            "by_kind" => { "complaint" => 1, "report" => 0, "praise" => 0, "suggestion" => 0, "request" => 0 }, "total" => 1 } ]
      )

      get "/ombudsman/dashboard/professionals", params: { from: "2025-01-01", to: "2025-12-31" }
      expect(json_body["items"].map { |item| item["total"] }).to eq([ 1 ])
    end

    it "o técnico → 403" do
      sign_in_as(technician)
      get "/ombudsman/dashboard/professionals"
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
    end

    it "período inválido → 422 invalid_period" do
      sign_in_as(ouvidor)
      get "/ombudsman/dashboard/professionals", params: { to: "ontem" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_period")
    end
  end
end
