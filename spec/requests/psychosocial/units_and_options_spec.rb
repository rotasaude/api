require "rails_helper"

# Módulo 31 (contrato P4, P31): GET /psychosocial/units (CAPS de lotação; para
# billing_clerk, municipal_admin e analyst, todos) e GET /psychosocial/options
# (listas do raas.yml, procedimentos pelo CBO do vínculo com as marcas
# family_care e collective, equipe do CAPS e equipes da APS).
RSpec.describe "CAPS — unidades e opções", type: :request do
  let!(:city) { psychosocial_city! }
  let!(:caps) { caps!(modality: "caps_ii", name: "CAPS II Boa Vista") }
  let!(:night) { caps!(modality: "caps_ad_iii", name: "CAPS AD III Centro Vida") }

  describe "GET /psychosocial/units" do
    it "a equipe vê só os CAPS em que está lotada" do
      staff = caps_staff!(caps)
      sign_in_as(staff)
      get "/psychosocial/units"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("items" => [ { "id" => caps.id, "name" => "CAPS II Boa Vista", "caps_modality" => "caps_ii",
                                              "night_capable" => false } ])
    end

    it "faturista, administrador e analista veem todos os CAPS ativos" do
      caps!(modality: "caps_i").update!(active: false)
      %w[billing_clerk municipal_admin analyst].each do |role|
        sign_in_as(staff_with("#{role}-#{SecureRandom.hex(3)}@cidade.gov.br", role))
        get "/psychosocial/units"
        expect(json_body["items"].map { |u| u["name"] }).to eq([ "CAPS AD III Centro Vida", "CAPS II Boa Vista" ])
        expect(json_body["items"].first).to include("night_capable" => true)
      end
    end

    it "sem papel do CAPS nem de leitura geral → 403 missing_role" do
      sign_in_as(ubs_doctor!(caps))
      get "/psychosocial/units"
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
    end
  end

  describe "GET /psychosocial/options" do
    it "listas, procedimentos do CAPS pelo CBO com as marcas, equipe e equipes da APS" do
      psychologist = caps_staff!(caps, cbo: "251510")
      lead = caps_staff!(caps, cbo: "223505", lead: true)
      caps_staff!(night, cbo: "322205")
      ubs_doctor!(caps)
      ubs = HealthUnit.create!(name: "UBS Vila Verde", kind: "ubs")
      team = HealthTeam.create!(health_unit: ubs, ine: "0000123456", kind: "70", name: "eSF Vila Verde 1")
      HealthTeam.create!(health_unit: ubs, ine: "0000123457", kind: "71", name: "eSB Vila Verde")
      HealthTeam.create!(health_unit: ubs, ine: "0000123458", kind: "76", name: "eAP antiga", active: false)

      sign_in_as(psychologist)
      get "/psychosocial/options", params: { health_unit_id: caps.id }
      expect(response).to have_http_status(:ok)

      expect(json_body["origins"].first).to eq("code" => "01", "label" => "Demanda espontânea")
      expect(json_body["destinations"].first).to eq("code" => "00", "label" => "Permanência")
      expect(json_body["substances"].map { |s| s["code"] }).to eq(%w[01 02 03 04 05 06 99])
      expect(json_body["intensities"]).to eq(%w[intensive semi_intensive non_intensive])
      expect(json_body).to include("places" => %w[caps territory], "group_kinds" => %w[group workshop assembly],
                                   "reception_outcomes" => %w[enrolled referred_elsewhere no_follow_up],
                                   "referral_priorities" => %w[routine priority], "night_sigtap_code" => "0301080020")

      codes = json_body["procedures"].map { |p| p["code"] }
      expect(codes).to match_array(SigtapSample::PSYCHOSOCIAL_CODES)
      expect(codes).not_to include("0301010064")
      family = json_body["procedures"].find { |p| p["code"] == "0301080224" }
      expect(family).to include("family_care" => true, "collective" => false, "instrument_codes" => %w[09])
      group = json_body["procedures"].find { |p| p["code"] == "0301080216" }
      expect(group).to include("family_care" => false, "collective" => true)
      reception = json_body["procedures"].find { |p| p["code"] == "0301080232" }
      expect(reception["instrument_codes"]).to eq(%w[02 09])
      expect(reception["name"]).to eq("ACOLHIMENTO INICIAL POR CENTRO DE ATENCAO PSICOSSOCIAL")
      # P56 (R2): limite e autorização da SIGTAP da competência corrente (nulo = sem limite).
      by_code = json_body["procedures"].index_by { |p| p["code"] }
      expect(by_code["0301080208"]).to include("max_quantity" => 31, "requires_authorization" => false)
      expect(by_code["0301080020"]).to include("max_quantity" => 1, "requires_authorization" => false)
      expect(by_code["0301080291"]).to include("max_quantity" => nil, "requires_authorization" => true)
      expect(json_body["procedures"]).to all(include("max_quantity", "requires_authorization"))

      expect(json_body["team"]).to contain_exactly(Psychosocial::Json.pro(psychologist, "251510"), Psychosocial::Json.pro(lead, "223505"))
      expect(json_body["health_teams"]).to eq([ { "id" => team.id, "name" => "eSF Vila Verde 1", "ine" => "0000123456",
                                                 "health_unit" => { "id" => ubs.id, "name" => "UBS Vila Verde" } } ])
      expect(response.body).not_to include("cpf", "cns")
    end

    it "traz o prazo de revisão do PTS da cidade (care_plan_review_days), sem exigir o papel de coordenação" do
      sign_in_as(caps_staff!(caps, cbo: "251510"))
      get "/psychosocial/options", params: { health_unit_id: caps.id }
      expect(json_body["care_plan_review_days"]).to eq(PsychosocialSetting.current.care_plan_review_days)

      PsychosocialSetting.current.update!(care_plan_review_days: 120)
      get "/psychosocial/options", params: { health_unit_id: caps.id }
      expect(json_body["care_plan_review_days"]).to eq(120)
    end

    it "CBO fora da lista do código some; código sem lista de CBO não restringe" do
      outsider = caps_staff!(caps, cbo: "225125")
      ProfessionalLink.active.where(health_unit_id: caps.id).find_each { |l| l.update!(ended_at: Time.current, ended_by_user: outsider) }
      link_professional!(outsider, caps, cbo: "515105")
      sign_in_as(outsider)
      get "/psychosocial/options", params: { health_unit_id: caps.id }
      expect(json_body["procedures"]).to eq([])

      # A SIGTAP ativa é imutável: uma release própria (competência antiga, que
      # não muda a da cidade) sem a relação de CBO do 0301080208 prova o ramo.
      release = Dir.mktmpdir do |dir|
        SigtapSample.write_to(dir, competence: "202001")
        file = File.join(dir, "rl_procedimento_ocupacao.txt")
        lines = File.binread(file).split("\r\n").reject { |line| line.start_with?("0301080208") }
        File.binwrite(file, lines.join("\r\n") + "\r\n")
        Terminology::Import.call(kind: "sigtap", version: "202001", path: dir, by: "rspec").payload.fetch(:release)
      end
      expect(SigtapProcedureCbo.where(release_id: release.id, procedure_code: "0301080208")).not_to exist
      allow(Terminology::Sigtap).to receive(:release_for).and_return(release)
      get "/psychosocial/options", params: { health_unit_id: caps.id }
      expect(json_body["procedures"].map { |p| p["code"] }).to eq(%w[0301080208])
    end

    it "lotação: sem health_unit_id → 422; outro CAPS → 403 not_on_caps_team; sem papel → 403 missing_role; query extra → 422" do
      staff = caps_staff!(caps)
      sign_in_as(staff)
      get "/psychosocial/options"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")
      get "/psychosocial/options", params: { health_unit_id: night.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("not_on_caps_team")
      get "/psychosocial/options", params: { health_unit_id: caps.id, q: "x" }
      expect(json_body).to include("error" => "invalid_request", "path" => "q")
      ubs = HealthUnit.create!(name: "UBS #{SecureRandom.hex(3)}", kind: "ubs")
      get "/psychosocial/options", params: { health_unit_id: ubs.id }
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")

      sign_in_as(ubs_doctor!(caps))
      get "/psychosocial/options", params: { health_unit_id: caps.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
    end

    it "coordenação sem vínculo no CAPS → 403 not_on_caps_team (a coordenação é lotada)" do
      sign_in_as(caps_staff!(night, cbo: "223505", lead: true))
      get "/psychosocial/options", params: { health_unit_id: caps.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("not_on_caps_team")
    end
  end
end

# P13 (ruling): o mapa de status das recusas do CAPS nasce completo.
RSpec.describe Psychosocial::BaseController do
  it "conflitos 409, recusas de papel 403, not_found 404" do
    map = described_class::FAILURE_STATUS
    %i[enrollment_open bed_taken already_staying already_exported bed_label_taken already_closed already_cancelled month_open
       record_not_open referral_not_pending].each { |code| expect(map[code]).to eq(:conflict) }
    %i[not_on_caps_team missing_role lead_required not_author out_of_context].each { |code| expect(map[code]).to eq(:forbidden) }
    expect(map[:not_found]).to eq(:not_found)
    expect(map.fetch(:caps_without_beds, :unprocessable_entity)).to eq(:unprocessable_entity)
  end

  it "render_failure leva ao topo só as chaves permitidas de details" do
    controller = described_class.new
    rendered = nil
    allow(controller).to receive(:render) { |**opts| rendered = opts }
    result = Result.fail(:night_limit_reached, details: { used: 15, limit: 14, window_days: 30, rule: "total", path: "started_at",
                                                          problems: [ { error: "night_limit_reached", path: "started_at" } ],
                                                          patient_name: "Renato Alves Pereira" })
    controller.send(:render_failure, result)
    expect(rendered[:status]).to eq(:unprocessable_entity)
    expect(rendered[:json]).to eq(error: "night_limit_reached", used: 15, limit: 14, window_days: 30, rule: "total", path: "started_at",
                                  problems: [ { error: "night_limit_reached", path: "started_at" } ])
  end
end
