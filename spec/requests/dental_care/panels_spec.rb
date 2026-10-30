require "rails_helper"

# Módulo 28 (ADR 0046; contrato §10, §16 O15/O24; Task 15): painel de metas do
# CEO. Leitores dos painéis (municipal_admin, analyst), só contagens, sem trilha.
RSpec.describe "Saúde bucal — painéis", type: :request do
  let!(:city) { dental_city! }
  let(:ceo) { ceo_unit!(type: "II") }
  let(:dentist) { dentist!(ceo) }
  let(:analyst) { staff_with("analista-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst") }
  let(:month) { Time.zone.today.strftime("%Y-%m") }

  def refusal(path) = { "error" => "invalid_request", "path" => path, "problems" => [ { "path" => path, "error" => "invalid_request" } ] }
  def goals(unit: ceo, month: self.month) = get("/dental/ceo_goals", params: { health_unit_id: unit.id, month: month }.compact)

  describe "GET /dental/ceo_goals" do
    let!(:consultation) { finalized_dental!(unit: ceo, by: dentist, citizen: verified_citizen!(1, social_name: "Mariana")) }

    it "analista → 200 na forma do §10 com history; goal/done numéricos, value string; sem trilha nem dado do paciente" do
      sign_in_as(analyst)
      expect { goals }.not_to change(DomainEvent, :count)
      expect(response.status).to eq(200)
      body = json_body
      expect(body.keys).to eq(%w[ceo_type specialties misses_last_12 suspension_risk history])
      expect(body.fetch("ceo_type")).to eq("II")
      basic = body.fetch("specialties").find { |row| row["key"] == "basic" }
      expect(basic).to eq("key" => "basic", "goal" => 110, "done" => 0,
                          "composition" => { "rule" => "restorations_min_50", "ok" => false, "value" => "0.00" }, "met" => false)
      expect(body.fetch("specialties").find { |row| row["key"] == "periodontics" }.fetch("composition")).to be_nil
      expect(body.fetch("misses_last_12").keys).to eq(%w[basic periodontics endodontics oral_surgery])
      expect(body.fetch("misses_last_12").fetch("basic")).to eq("consecutive" => 0, "total" => 0) # perfil criado agora
      expect([ body.fetch("suspension_risk"), body.fetch("history") ]).to eq([ false, [] ])
      expect(response.body).not_to match(/patient|Mariana|Maria|cpf|cns/i)
    end

    it "admin municipal → 200" do
      sign_in_as(dental_admin!)
      goals
      expect(response.status).to eq(200)
    end

    it "profissional sem papel de painel → 403 missing_role" do
      sign_in_as(dentist)
      goals
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end

    it "interruptor desligado → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "dental_care", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(analyst)
      goals
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "dental_care" } ])
    end

    it "unidade que não é CEO, ou CEO sem perfil → 422 unit_not_ceo; unidade inexistente → 404" do
      sign_in_as(analyst)
      goals(unit: create_unit("UBS Centro"))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "unit_not_ceo" } ])
      goals(unit: create_unit("CEO sem perfil", kind: "ceo"))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "unit_not_ceo" } ])
      get "/dental/ceo_goals", params: { health_unit_id: SecureRandom.uuid, month: month }
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end

    it "month ausente, inválido ou futuro → 422 invalid_request em month; health_unit_id inválido → em health_unit_id" do
      sign_in_as(analyst)
      [ nil, "2026-13", "2026-1", "out", Time.zone.today.next_month.strftime("%Y-%m") ].each do |value|
        goals(month: value)
        expect([ response.status, json_body ]).to eq([ 422, refusal("month") ])
      end
      get "/dental/ceo_goals", params: { health_unit_id: "x", month: month }
      expect([ response.status, json_body ]).to eq([ 422, refusal("health_unit_id") ])
    end
  end
end
