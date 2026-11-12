require "rails_helper"

# Módulo 33, Task 16 (ADR 0051; contrato §11; §16 Q27, Q35): o relatório de
# gestão anual — só o ouvidor. GET sempre 200 (rascunho vazio, sem gravar);
# PATCH grava o rascunho (textos até 8000, sem cifra: documento público);
# publicar só ano encerrado (422 year_not_closed) e congela os números.
RSpec.describe "Ouvidoria — relatório de gestão anual", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let(:technician) { ombudsman_staff! }
  let(:ouvidor) { ombudsman! }
  let(:suppressed) { { "suppressed" => true } }
  let(:received_2025) { Time.utc(2025, 5, 10, 15) }

  before { travel_to(Time.utc(2026, 11, 11, 15)) }
  after { travel_back }

  def report(year) = get("/ombudsman/annual_reports/#{year}")
  def save(year, params) = json_patch("/ombudsman/annual_reports/#{year}", params)
  def publish(year) = json_post("/ombudsman/annual_reports/#{year}/publish", {})
  def row(year) = OmbudsmanAnnualReport.find_by(year: year)

  describe "GET" do
    it "ano sem linha: 200 com um rascunho vazio e os números vivos; nada é gravado" do
      6.times { manifestation!(received_at: received_2025) }
      sign_in_as(ouvidor)

      report(2025)
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to eq(%w[year state recurring_problems actions_taken notes numbers published_at])
      expect(json_body).to include("year" => 2025, "state" => "draft", "recurring_problems" => nil, "actions_taken" => nil,
                                   "notes" => nil, "published_at" => nil)
      expect(json_body["numbers"]["period"]).to eq("from" => "2025-01-01", "to" => "2025-12-31")
      expect(json_body["numbers"]["by_kind"]["complaint"]).to eq(6)
      expect(OmbudsmanAnnualReport.count).to eq(0)
    end

    it "técnico e quem não é da ouvidoria → 403" do
      sign_in_as(technician)
      report(2025)
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
    end

    it "ano que não é AAAA entre 2000 e 2999 → 404" do
      sign_in_as(ouvidor)
      [ "abc", "1999", "3000", "25" ].each do |year|
        report(year)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "PATCH" do
    it "grava o rascunho (cria a linha na primeira vez) e o GET devolve os textos; sem cifra" do
      sign_in_as(ouvidor)
      save(2025, recurring_problems: "  Demora no agendamento.  ", actions_taken: "Mutirão de consultas.")
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("year" => 2025, "state" => "draft", "recurring_problems" => "Demora no agendamento.",
                                   "actions_taken" => "Mutirão de consultas.", "notes" => nil)
      expect(OmbudsmanAnnualReport.connection.select_value("SELECT recurring_problems FROM ombudsman_annual_reports")).to eq("Demora no agendamento.")

      save(2025, notes: "Observação.", actions_taken: nil)
      expect(json_body).to include("recurring_problems" => "Demora no agendamento.", "actions_taken" => nil, "notes" => "Observação.")
      expect(OmbudsmanAnnualReport.count).to eq(1)

      report(2025)
      expect(json_body).to include("recurring_problems" => "Demora no agendamento.", "notes" => "Observação.")
    end

    it "cada texto até 8000; acima, não-texto ou chave desconhecida → 422 com o path" do
      sign_in_as(ouvidor)
      save(2025, notes: "x" * 8000)
      expect(response).to have_http_status(:ok)
      save(2025, notes: "x" * 8001)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "notes")
      save(2025, actions_taken: 12)
      expect(json_body).to include("error" => "invalid_request", "path" => "actions_taken")
      save(2025, snapshot: {})
      expect(json_body).to include("error" => "invalid_request", "path" => "snapshot")
      save(2025, state: "published")
      expect(json_body).to include("error" => "invalid_request", "path" => "state")
      expect(row(2025).notes).to eq("x" * 8000)
    end

    it "o técnico → 403" do
      sign_in_as(technician)
      save(2025, notes: "a")
      expect(response).to have_http_status(:forbidden)
      expect(OmbudsmanAnnualReport.count).to eq(0)
    end
  end

  describe "POST publish" do
    it "publica o ano encerrado: congela os números (com a supressão) e depois nada muda" do
      6.times { manifestation!(received_at: received_2025) }
      3.times { manifestation!(received_at: received_2025, kind: "praise") }
      sign_in_as(ouvidor)
      save(2025, recurring_problems: "Fila.")

      publish(2025)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("year" => 2025, "state" => "published", "recurring_problems" => "Fila.")
      expect(json_body["published_at"]).to be_present
      expect(json_body["numbers"]["by_kind"]).to include("complaint" => suppressed, "praise" => suppressed, "total" => 9)
      frozen = json_body["numbers"]
      expect(row(2025)).to have_attributes(state: "published", published_by_user_id: ouvidor.id)
      expect(row(2025).snapshot).to eq(frozen)

      # uma manifestação nova de 2025, depois de publicar, não mexe nos números
      manifestation!(received_at: received_2025)
      report(2025)
      expect(json_body["state"]).to eq("published")
      expect(json_body["numbers"]).to eq(frozen)

      save(2025, notes: "tarde demais")
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "report_published")

      publish(2025)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "already_published")
      expect(row(2025).notes).to be_nil
    end

    it "a linha criada na publicação leva o horário da publicação (now)" do
      sign_in_as(ouvidor)
      publish(2025)
      expect(row(2025)).to have_attributes(created_at: Time.current, updated_at: Time.current, published_at: Time.current)
    end

    it "sem rascunho prévio publica com os textos vazios" do
      sign_in_as(ouvidor)
      publish(2025)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("state" => "published", "recurring_problems" => nil)
    end

    it "ano corrente ou futuro → 422 year_not_closed e nada é gravado" do
      sign_in_as(ouvidor)
      [ 2026, 2027 ].each do |year|
        publish(year)
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to include("error" => "year_not_closed")
      end
      expect(OmbudsmanAnnualReport.count).to eq(0)
    end

    it "o ano corrente vale no fuso da cidade: 31/12 às 22h de Brasília ainda é o ano corrente" do
      travel_to(Time.utc(2027, 1, 1, 1))
      sign_in_as(ouvidor)
      publish(2026)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]).to eq("year_not_closed")
    end

    it "o técnico → 403; ano inválido → 404" do
      sign_in_as(technician)
      publish(2025)
      expect(response).to have_http_status(:forbidden)
      sign_in_as(ouvidor)
      publish("abc")
      expect(response).to have_http_status(:not_found)
    end
  end
end
