require "rails_helper"

# Módulo 28 (ADR 0046; contrato §10, §16 O11/O15/O23/O24; Tasks 15 e 16): painel
# de metas do CEO, indicadores B1/B2 da eSB e a lista das eSB. Leitores dos
# painéis (municipal_admin, analyst), só contagens, sem trilha.
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
  describe "GET /dental/indicators" do
    let(:unit) { create_unit("UBS Bucal #{SecureRandom.hex(2)}") }
    let(:esf) { HealthTeam.create!(health_unit: unit, ine: "0001234570", kind: "70", name: "eSF Jardim") }
    let(:esb) { HealthTeam.create!(health_unit: unit, ine: "0001234571", kind: "71", name: "eSB Jardim", associated_team: esf) }
    let(:period) { Time.zone.today.strftime("%Y-%m") }

    def indicators(team_id: esb.id, period: self.period) = get("/dental/indicators", params: { team_id: team_id, period: period }.compact)

    # O paciente está na população da eSF associada (consulta geral de membro dela).
    before do
      citizen = verified_citizen!(1, social_name: "Mariana")
      doctor = doctor!(unit)
      HealthTeamMember.create!(professional: doctor.professional, health_team: esf, cbo_code: "225125", started_on: Time.zone.today - 30)
      finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen, exam_requests: [])
      user = dentist!(unit)
      HealthTeamMember.create!(professional: user.professional, health_team: esb, cbo_code: "223208", started_on: Time.zone.today - 30)
      consultation = dental_draft_row!(unit: unit, by: user, citizen: citizen)
      consultation.update_columns(status: "finalized", finalized_at: Time.current, care_type: 2, dental_consultation_type: 1,
                                  dental_outcomes: [ 15 ])
    end

    it "analista → 200 { b1, b2 } com numerador e denominador; sem trilha nem dado do paciente" do
      sign_in_as(analyst)
      expect { indicators }.not_to change(DomainEvent, :count)
      expect([ response.status, json_body ]).to eq([ 200, { "b1" => { "numerator" => 1, "denominator" => 1 },
                                                             "b2" => { "numerator" => 1, "denominator" => 1 } } ])
      expect(response.body).not_to match(/patient|Mariana|Maria|cpf|cns/i)
    end

    it "eSB sem associada → denominator null no B1" do
      esb.update!(associated_team: nil)
      sign_in_as(dental_admin!)
      indicators
      expect([ response.status, json_body.fetch("b1") ]).to eq([ 200, { "numerator" => 1, "denominator" => nil } ])
    end

    it "profissional sem papel de painel → 403 missing_role; interruptor desligado → 403 feature_disabled" do
      sign_in_as(dentist)
      indicators
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      Platform::Features.set!(city: city, key: "dental_care", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(analyst)
      indicators
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "dental_care" } ])
    end

    it "equipe que não é eSB ou team_id inválido → 422 em team_id; inexistente → 404" do
      sign_in_as(analyst)
      [ esf.id, "x", nil ].each do |value|
        indicators(team_id: value)
        expect([ response.status, json_body ]).to eq([ 422, refusal("team_id") ])
      end
      indicators(team_id: SecureRandom.uuid)
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end

    it "period ausente, inválido ou futuro → 422 invalid_request em period" do
      sign_in_as(analyst)
      [ nil, "2026-13", "2026-1", "out", Time.zone.today.next_month.strftime("%Y-%m") ].each do |value|
        indicators(period: value)
        expect([ response.status, json_body ]).to eq([ 422, refusal("period") ])
      end
    end
  end

  describe "GET /dental/teams" do
    let(:unit) { create_unit("UBS Bucal #{SecureRandom.hex(2)}") }
    let!(:esf) { HealthTeam.create!(health_unit: unit, ine: "0001234570", kind: "70", name: "eSF Jardim") }
    let!(:esb) { HealthTeam.create!(health_unit: unit, ine: "0001234571", kind: "71", name: "eSB Jardim", associated_team: esf) }
    let!(:esb2) { HealthTeam.create!(health_unit: unit, ine: "0001234572", kind: "71", name: "eSB Bosque") }
    let!(:inactive) { HealthTeam.create!(health_unit: unit, ine: "0001234573", kind: "71", name: "eSB Antiga", active: false) }

    it "analista → só as eSB ativas, por nome, na forma do O23; limit corta a página" do
      sign_in_as(analyst)
      get "/dental/teams"
      expect(response.status).to eq(200)
      expect(json_body).to eq("teams" => [ esb2, esb ].map do |team|
        { "id" => team.id, "name" => team.name, "ine" => team.ine, "health_unit" => { "id" => unit.id, "name" => unit.name } }
      end)
      get "/dental/teams", params: { limit: 1 }
      expect(json_body.fetch("teams").map { |team| team["id"] }).to eq([ esb2.id ])
      get "/dental/teams", params: { limit: 0 }
      expect([ response.status, json_body.fetch("error") ]).to eq([ 422, "invalid_limit" ])
    end

    it "profissional sem papel de painel → 403 missing_role" do
      sign_in_as(dentist)
      get "/dental/teams"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end
end
