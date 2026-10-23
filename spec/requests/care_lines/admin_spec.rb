require "rails_helper"

# Contrato §3: admin municipal; escrita com step-up; 422 com os códigos.
RSpec.describe "Linhas de cuidado — linhas da cidade", type: :request do
  before do
    care_city!
    care_lines_loaded!
  end

  let(:admin) { care_admin! }
  let(:mental) do
    { name: "Saúde mental — acompanhamento", declared_condition: "mental_health",
      eligibility: { problems: { ciap2: %w[P74 P76], cid10: %w[F32 F33 F41] }, declared: %w[mental_health] },
      practices: [ { key: "sm_a", label: "Consulta a cada 3 meses", citizen_label: "Consulta de acompanhamento", source: "consultation",
                     anchor: "rolling", window_days: 92, min_count: 1, schedule: "end_of_window", cbo_filter: %w[2251 2235 2515] } ] }
  end

  it "templates: as seis linhas, versão mais nova; profissional não lê" do
    sign_in_as(admin)
    get "/care_lines/admin/templates"
    expect(json_body["templates"].map { |t| [ t["key"], t["version"], t["indicator"] ] })
      .to eq(CareLines::Catalog::TEMPLATE_KEYS.map { |k| [ k, 1, CareLines::Catalog::INDICATORS[k] ] })
    sign_in_as(care_doctor!(care_unit!))
    get "/care_lines/admin/templates"
    expect(response).to have_http_status(:forbidden)
  end

  it "adota com step-up (cópia da versão), recusa adoção repetida, publica só ids" do
    sign_in_as(admin)
    json_post "/care_lines/admin/lines", template_key: "diabetes_c4", template_version: 1
    expect(json_body).to eq("error" => "mfa_required")
    stepped_up!(admin)
    json_post "/care_lines/admin/lines", template_key: "diabetes_c4", template_version: 1
    expect(response).to have_http_status(:created)
    expect(json_body).to include("source" => "template", "template_key" => "diabetes_c4", "template_version" => 1, "indicator" => "C4",
                                 "declared_condition" => "diabetes", "active" => true)
    expect(json_body["practices"].map { |p| p["key"] }).to eq(%w[c4_a c4_b c4_c c4_d c4_e c4_f])
    expect(DomainEvent.where(name: "care_line.adopted").last.payload.keys).to match_array(%w[care_line_id user_id])
    json_post "/care_lines/admin/lines", template_key: "diabetes_c4", template_version: 1
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "duplicate_template")
    json_post "/care_lines/admin/lines", template_key: "elderly_c6", template_version: 9
    expect(json_body).to eq("error" => "template_not_found")
  end

  it "corrida de adoção: o perdedor passa na pré-checagem e ainda recebe duplicate_template, não duplicate_declared_condition" do
    stepped_up!(admin)
    json_post "/care_lines/admin/lines", template_key: "diabetes_c4", template_version: 1
    expect(response).to have_http_status(:created)
    calls = 0
    allow(CareLine).to receive(:exists?).and_call_original
    allow(CareLine).to receive(:exists?).with(template_key: "diabetes_c4") do
      calls += 1
      calls == 1 ? false : CareLine.where(template_key: "diabetes_c4").exists? # 1ª: a pré-checagem do perdedor; 2ª: a consulta do rescue
    end
    json_post "/care_lines/admin/lines", template_key: "diabetes_c4", template_version: 1
    expect(calls).to eq(2)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "duplicate_template")
  end

  it "versão nova do template só vale quando a cidade adota (PATCH template_version)" do
    stepped_up!(admin)
    json_post "/care_lines/admin/lines", template_key: "hypertension_c5", template_version: 1
    line = CareLine.find(json_body["id"])
    t = CareLineTemplate.current("hypertension_c5")
    CareLines::Templates::Save.call(t.attributes.slice(*%w[key indicator declared_condition eligibility])
                                     .merge("name" => "Hipertensão (2027)", "practices" => t.practices.map { |p| p.merge("window_days" => p["window_days"] + 1) }))
    expect(line.reload.practices.first["window_days"]).to eq(183)
    get "/care_lines/admin/lines"
    expect(json_body["lines"].sole).to include("template_version" => 1, "latest_template_version" => 2)
    patch "/care_lines/admin/lines/#{line.id}", params: { template_version: 2 }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("template_version" => 2, "latest_template_version" => 2)
    expect(line.reload).to have_attributes(template_version: 2, name: "Hipertensão (2027)")
    expect(line.practices.first["window_days"]).to eq(184)
    patch "/care_lines/admin/lines/#{line.id}", params: { practices: [] }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(json_body).to eq("error" => "immutable_rules")
  end

  it "linha própria: cria, recusa regra inválida com field, nome longo e condição já usada; desativa" do
    stepped_up!(admin)
    json_post "/care_lines/admin/lines", mental
    expect(response).to have_http_status(:created)
    expect(json_body).to include("source" => "custom", "template_key" => nil, "indicator" => nil, "declared_condition" => "mental_health",
                                 "latest_template_version" => nil)
    id = json_body["id"]
    json_post "/care_lines/admin/lines", mental.merge(name: "Outra saúde mental")
    expect(json_body).to eq("error" => "duplicate_declared_condition")
    bad = mental.merge(declared_condition: nil, practices: [ mental[:practices].first.merge(source: "lab:1") ])
    json_post "/care_lines/admin/lines", bad
    expect(json_body).to eq("error" => "invalid_practices", "field" => "practices[0].source")
    json_post "/care_lines/admin/lines", mental.merge(declared_condition: nil, name: "x" * 121)
    expect(json_body).to eq("error" => "invalid_name")
    json_post "/care_lines/admin/lines", mental.merge(declared_condition: nil, eligibility: {})
    expect(json_body).to eq("error" => "invalid_eligibility", "field" => "eligibility")
    patch "/care_lines/admin/lines/#{id}", params: { active: false }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(json_body["active"]).to be(false)
    get "/care_lines/admin/lines"
    expect(json_body["lines"].map { |l| l["id"] }).to eq([ id ])
  end

  it "listas de apoio: linhas ativas e equipes visíveis (profissional: as das unidades dele)" do
    unit = care_unit!
    doctor = care_doctor!(unit)
    mine = care_team!(unit, doctor)
    other = care_team!(care_unit!)
    adopted_line!("elderly_c6")
    sign_in_as(doctor)
    get "/care_lines/lines"
    expect(json_body["lines"].map { |l| l["name"] }).to eq([ "Pessoa idosa" ])
    get "/care_lines/teams"
    expect(json_body["teams"].map { |t| t["id"] }).to eq([ mine.id ])
    sign_in_as(admin)
    get "/care_lines/teams"
    expect(json_body["teams"].map { |t| t["id"] }).to contain_exactly(mine.id, other.id)
  end

  it "equipes trazem can_confirm: médico (2231 e 2251) e enfermeiro sim; técnica e gestão não (§11 T2, L3)" do
    unit = care_unit!
    doctor = care_doctor!(unit)
    nurse = care_nurse!(unit)
    # 223115 (família 2231, L3) ainda não está em config/professionals/cbo_saude.yml; o vínculo novo
    # exigiria o código no catálogo, então o catálogo ganha a entrada só neste exemplo.
    family_cbo = Professionals::Cbo::Entry.new(code: "223115", title: "Médico (família 2231)", council: "CRM", deprecated: false)
    allow(Professionals::Cbo).to(receive(:all).and_wrap_original { |original| original.call + [ family_cbo ] })
    family = screener!(unit, cbo: "223115")
    tech = screener!(unit, cbo: "322205")
    mine = care_team!(unit, doctor)
    other = care_team!(care_unit!)
    { doctor => true, nurse => true, family => true, tech => false }.each do |user, expected|
      sign_in_as(user)
      get "/care_lines/teams"
      expect(json_body["teams"].map { |t| [ t["id"], t["can_confirm"] ] }).to eq([ [ mine.id, expected ] ]), user.email_address
    end
    sign_in_as(admin)
    get "/care_lines/teams"
    expect(json_body["teams"].map { |t| [ t["id"], t["can_confirm"] ] }).to contain_exactly([ mine.id, false ], [ other.id, false ])
  end

  it "equipes trazem panel pela regra do painel nominal: secretário médico (profissional e admin) só no vínculo dele (P22)" do
    unit = care_unit!
    doctor = care_doctor!(unit)
    Membership.create!(user: doctor, role: "municipal_admin", granted_at: Time.current)
    mine = care_team!(unit, doctor)
    other = care_team!(care_unit!)
    sign_in_as(doctor)
    get "/care_lines/teams"
    expect(json_body["teams"].map { |t| [ t["id"], t["panel"], t["can_confirm"] ] })
      .to contain_exactly([ mine.id, true, true ], [ other.id, false, false ])
    sign_in_as(admin)
    get "/care_lines/teams"
    expect(json_body["teams"].map { |t| [ t["id"], t["panel"] ] }).to contain_exactly([ mine.id, false ], [ other.id, false ])
    sign_in_as(care_nurse!(unit))
    get "/care_lines/teams"
    expect(json_body["teams"].map { |t| [ t["id"], t["panel"] ] }).to eq([ [ mine.id, true ] ])
  end

  it "profissional sem vínculo ativo não lê as listas de apoio: 403 missing_role (P5f)" do
    sign_in_as(staff_with("sem-vinculo-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional"))
    get "/care_lines/teams"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")
    get "/care_lines/lines"
    expect(response).to have_http_status(:forbidden)
  end

  it "care_lines desligado: 403 feature_disabled" do
    Platform::Features.set!(city: Current.city, key: "care_lines", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(admin)
    get "/care_lines/admin/lines"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "care_lines")
  end
end
