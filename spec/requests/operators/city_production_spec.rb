require "rails_helper"

# Contratos §4.3 e §8: resumo por cidade (corrente primeiro, depois a anterior)
# no envelope { data: ... }, do banco de PLATAFORMA; terminology com o alerta de
# SIGTAP do dia 5 (America/Sao_Paulo). `sending` é contagem própria e não entra
# em `pending` (R18). `deadline_estimated_on` só quando difere da data oficial.
RSpec.describe "GET /city_production (console do operador)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:password) { "s3nha-forte-1" }
  let!(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end
  let!(:maringa) { create(:city, name: "Maringá", uf: "PR").tap { |c| c.update!(record_mode: "record") } }
  let!(:off_city) { create(:city, name: "Desligada", uf: "PR") }
  let!(:archived) { create(:city, name: "Arquivada", status: "archived").tap { |c| c.update!(record_mode: "record") } }

  def json = JSON.parse(response.body)

  def verified_login!
    host! "admin.rotasaude.app"
    post "/session", params: { email_address: operator.email_address, password: password }
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(operator.otp_secret).now }
    expect(response).to have_http_status(:ok)
  end

  it "lista as cidades ativas fora de off, competência corrente primeiro, com prazo e alerta recalculados" do
    travel_to Time.zone.local(2026, 11, 10, 12) do
      CityProductionSummary.create!(city_id: maringa.id, competence: "202610", accepted: 0, rejected: 2, pending: 1,
                                    sending: 3, failed: 0, published_at: Time.current)
      verified_login!
      get "/city_production"

      expect(response).to have_http_status(:ok)
      cities = json.dig("data", "cities")
      expect(cities.map { |c| c["slug"] }).to eq([ maringa.slug ])
      entry = cities.sole
      expect(entry.slice("name", "record_mode")).to eq("name" => "Maringá", "record_mode" => "record")
      expect(entry["competences"].map { |c| c["competence"] }).to eq(%w[202611 202610])
      expect(entry["competences"].last).to eq(
        "competence" => "202610", "deadline_on" => "2026-11-16", "business_days_left" => 5,
        "accepted" => 0, "rejected" => 2, "pending" => 1, "sending" => 3, "failed" => 0, "alert" => "attention"
      )
      expect(entry["competences"].first.slice("accepted", "rejected", "pending", "sending", "failed"))
        .to eq("accepted" => 0, "rejected" => 0, "pending" => 0, "sending" => 0, "failed" => 0)
    end
  end

  it "deadline_estimated_on só aparece quando a data estimada difere da oficial" do
    travel_to Time.zone.local(2026, 6, 10, 12) do
      verified_login!
      get "/city_production"
      competences = json.dig("data", "cities").sole["competences"]
      expect(competences.map { |c| c["competence"] }).to eq(%w[202606 202605])
      previous = competences.last
      expect(previous["deadline_on"]).to eq("2026-06-16")
      expect(previous["deadline_estimated_on"]).to eq("2026-06-15")
      expect(competences.first).not_to have_key("deadline_estimated_on")
    end
  end

  it "terminology: SIGTAP da competência corrente e o alerta do dia 5" do
    travel_to Time.zone.local(2026, 11, 5, 9) do
      verified_login!
      get "/city_production"
      expect(json.dig("data", "terminology")).to eq("sigtap_current_competence" => "202611", "sigtap_imported" => false,
                                                    "sigtap_alert" => true)
      TerminologyRelease.create!(kind: "sigtap", version: "202611", status: "active", source_sha256: "0" * 64,
                                 imported_by: "spec", imported_at: Time.current)
      get "/city_production"
      expect(json.dig("data", "terminology")).to include("sigtap_imported" => true, "sigtap_alert" => false)
    end
    travel_to Time.zone.local(2026, 12, 4, 9) do
      verified_login!
      get "/city_production"
      expect(json.dig("data", "terminology")).to include("sigtap_imported" => false, "sigtap_alert" => false)
    end
  end

  it "sem sessão de operador: 401; host de cidade: 404" do
    host! "admin.rotasaude.app"
    get "/city_production"
    expect(response).to have_http_status(:unauthorized)

    host! "#{maringa.slug}.rotasaude.app"
    get "/city_production"
    expect(response).to have_http_status(:not_found)
  end
end
