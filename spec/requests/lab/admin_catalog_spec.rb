require "rails_helper"

# Contrato §3 (F-21.15) com as formas do dashboard (D12): adotar do
# catálogo-base, nova versão (nunca edita), motivos de rejeição, flags.
RSpec.describe "Laboratório — admin do catálogo", type: :request do
  before do
    lab_city!
    Lab::Templates::SaveExam.call(sigtap_code: "0202010473", name: "Glicose", sector: "biochemistry", material: "Plasma",
                                  container: "Tubo cinza (fluoreto)", suggested_method: "Enzimático", active: true)
    Lab::Templates::SaveAnalyte.call(lab_exam_template_id: template.id, key: "glicose", name: "Glicose", loinc: "2345-7", unit: "mg/dL",
                                     value_type: "numeric", choices: [], decimals: 0, position: 1,
                                     reference_ranges: [ { sex: "any", age_min_days: 0, age_max_days: 43_800, low: 70, high: 99, text: nil } ])
  end

  let(:template) { LabExamTemplate.find_by!(sigtap_code: "0202010473") }
  let(:provider) { lab_provider! }
  let(:admin) { lab_admin! }

  it "adota, cria versão nova, edita prazo; o laudo antigo continua com a versão dele" do
    stepped_up!(admin)
    get "/lab/admin/templates"
    expect(json_body["templates"].first).to include("sigtap_code" => "0202010473", "sector" => "biochemistry",
                                                    "analytes" => [ hash_including("key" => "glicose", "value_type" => "numeric") ])
    json_post "/lab/admin/exams", provider_id: provider.id, template_id: template.id, sector: "biochemistry", bench: "Bancada 1", delivery_days: 2
    expect(response).to have_http_status(:created)
    exam = json_body
    expect(exam).to include("sigtap_code" => "0202010473", "name" => "Glicose", "delivery_days" => 2, "active" => true)
    expect(exam["current_version"]).to include("version" => 1, "method" => "Enzimático", "material" => "Plasma", "instrument_test_code" => nil)
    expect(exam["current_version"]["analytes"].first).to include("entry_min" => nil, "critical_high" => nil, "formula" => nil)
    json_post "/lab/admin/exams", provider_id: provider.id, template_id: template.id, sector: "biochemistry", bench: nil, delivery_days: 2
    expect(json_body["error"]).to eq("duplicate_sigtap")

    analytes = exam["current_version"]["analytes"].map { |a| a.merge("critical_high" => 400, "entry_max" => 1500) }
    json_post "/lab/admin/exams/#{exam['id']}/versions", method: "Enzimático (GOD-PAP)", material: "Plasma", container: "Tubo cinza",
                                                        instrument_test_code: "GLI", analytes: analytes
    expect(response).to have_http_status(:created)
    expect(json_body).to include("version" => 2, "instrument_test_code" => "GLI")
    expect(LabExam.find(exam["id"]).versions.map(&:version)).to eq([ 1, 2 ])
    json_post "/lab/admin/exams/#{exam['id']}/versions", method: "x", material: "Plasma", container: "x", instrument_test_code: "GLI",
                                                        analytes: analytes.map { |a| a.merge("formula" => "glicose * 2") }
    expect(json_body["error"]).to eq("invalid_formula")
    other = lab_exam!(provider: provider, sigtap_code: "0202010317", name: "Creatinina", instrument_test_code: "CRE")
    json_post "/lab/admin/exams/#{other.id}/versions", method: "Jaffé", material: "Soro", container: "Tubo amarelo",
                                                       instrument_test_code: "GLI", analytes: LabHelpers::GLUCOSE
    expect(json_body["error"]).to eq("duplicate_instrument_code")

    json_patch "/lab/admin/exams/#{exam['id']}", sector: "biochemistry", bench: nil, delivery_days: 5, active: false
    expect(json_body).to include("delivery_days" => 5, "active" => false, "bench" => nil)
    get "/lab/admin/exams/#{exam['id']}"
    expect(json_body["versions"].map { |v| v["version"] }).to eq([ 1, 2 ])
    expect(DomainEvent.where(name: "lab_exam.version_created").count).to eq(2)
  end

  it "motivos de rejeição; recepção lê só os ativos" do
    stepped_up!(admin)
    json_post "/lab/admin/rejection_reasons", provider_id: provider.id, name: "Amostra hemolisada", active: true
    reason = json_body
    json_post "/lab/admin/rejection_reasons", provider_id: provider.id, name: "amostra HEMOLISADA", active: true
    expect(json_body["error"]).to eq("duplicate_name")
    json_post "/lab/admin/rejection_reasons", provider_id: provider.id, name: "Volume insuficiente", active: true
    json_patch "/lab/admin/rejection_reasons/#{reason['id']}", name: "Amostra hemolisada", active: false
    json_patch "/lab/admin/rejection_reasons/#{reason['id']}", name: "Amostra hemolisada (lipemia)"
    expect(json_body).to include("name" => "Amostra hemolisada (lipemia)", "active" => false)
    sign_in_as(lab_staff!)
    get "/lab/rejection_reasons", params: { provider_id: provider.id }
    expect(json_body["reasons"].map { |r| r["name"] }).to eq([ "Volume insuficiente" ])
  end

  it "sem step-up 401; sem papel 403; interruptor desligado 403" do
    sign_in_as(admin)
    json_post "/lab/admin/exams", provider_id: provider.id, template_id: template.id, sector: "biochemistry", delivery_days: 2
    expect(json_body["error"]).to eq("mfa_required")
    sign_in_as(lab_staff!)
    get "/lab/admin/templates"
    expect(json_body["error"]).to eq("missing_role")
    Platform::Features.set!(city: City.find(Current.city.id), key: "municipal_lab", enabled: false, maintainer: ledi_maintainer!)
    get "/lab/context"
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "municipal_lab")
  end

  it "prestador marca uses_municipal_lab, endereço e telefone; unidade marca collects_samples" do
    stepped_up!(admin)
    lab = exam_provider!(name: "Lab Novo", items: [])
    json_patch "/exams/admin/providers/#{lab.id}", uses_municipal_lab: true, address: "Rua A, 1", phone: "4133334444"
    expect(json_body).to include("uses_municipal_lab" => true, "address" => "Rua A, 1", "phone" => "4133334444", "has_middleware_token" => false)
    json_patch "/exams/admin/providers/#{lab.id}", phone: "123"
    expect(json_body["error"]).to eq("invalid_phone")
    unit = create_unit("UBS Coleta")
    json_post "/attendance/units/#{unit.id}", name: unit.name, kind: "ubs", collects_samples: true
    expect(json_body.dig("unit", "collects_samples")).to be(true)
    json_post "/attendance/units/#{unit.id}", name: unit.name, kind: "ubs", collects_samples: "sim"
    expect(json_body["error"]).to eq("invalid_collects_samples")
  end

  it "código do aparelho sem diferença de caixa, só entre exames ATIVOS; PATCH do exame recusa entrada inválida" do
    stepped_up!(admin)
    glucose = lab_exam!(provider: provider, instrument_test_code: "GLI")
    creat = lab_exam!(provider: provider, sigtap_code: "0202010317", name: "Creatinina", instrument_test_code: "CRE")
    body = { method: "Jaffé", material: "Soro", container: "Tubo amarelo", instrument_test_code: " gli ", analytes: LabHelpers::GLUCOSE }
    json_post "/lab/admin/exams/#{creat.id}/versions", **body
    expect([ response.status, json_body["error"] ]).to eq([ 422, "duplicate_instrument_code" ])
    glucose.update!(active: false)
    json_post "/lab/admin/exams/#{creat.id}/versions", **body
    expect(response).to have_http_status(:created)
    expect(json_body["instrument_test_code"]).to eq("GLI")

    valid = { sector: "biochemistry", bench: nil, delivery_days: 3, active: true }
    { { sector: "x" } => "invalid_sector", { delivery_days: 0 } => "invalid_delivery_days", { delivery_days: "3" } => "invalid_delivery_days",
      { active: "sim" } => "invalid_active", { bench: "b" * 61 } => "invalid_bench" }.each do |change, code|
      json_patch "/lab/admin/exams/#{creat.id}", valid.merge(change)
      expect([ response.status, json_body["error"] ]).to eq([ 422, code ]), change.inspect
    end
    expect(creat.reload).to have_attributes(delivery_days: 3, active: true)
  end

  it "D20: marcar uses_municipal_lab com o interruptor desligado → municipal_lab_disabled" do
    stepped_up!(admin)
    lab = exam_provider!(name: "Lab Desligado", items: [])
    Platform::Features.set!(city: City.find(Current.city.id), key: "municipal_lab", enabled: false, maintainer: ledi_maintainer!)
    json_patch "/exams/admin/providers/#{lab.id}", uses_municipal_lab: true
    expect([ response.status, json_body["error"] ]).to eq([ 422, "municipal_lab_disabled" ])
    expect(lab.reload.uses_municipal_lab).to be(false)
    json_patch "/exams/admin/providers/#{lab.id}", uses_municipal_lab: false
    expect(response).to have_http_status(:ok)
  end
end
