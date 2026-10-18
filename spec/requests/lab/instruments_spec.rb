require "rails_helper"

# Contrato §2 (F-21.25): aparelhos do laboratório (admin com step-up),
# leitura para os membros, identificador HL7 único no laboratório (sem
# diferenciar caixa) e o vínculo exame × aparelho na versão do exame.
RSpec.describe "Laboratório — aparelhos", type: :request do
  before { qc_city! }

  let(:provider) { lab_provider! }
  let(:admin) { lab_admin! }
  let(:payload) do
    { provider_id: provider.id, name: "Analisador bioquímico 1", manufacturer: "Mindray", model: "BS-240", serial_number: "BS24-0001",
      sector: "biochemistry", hl7_equipment_id: "BIO-01", active: true }
  end

  it "admin cadastra, edita e desativa; recusas de nome, setor, identificador e duplicado" do
    stepped_up!(admin)
    json_post "/lab/admin/instruments", payload
    expect(response).to have_http_status(:created)
    created = json_body
    expect(created).to include("name" => "Analisador bioquímico 1", "sector" => "biochemistry", "hl7_equipment_id" => "BIO-01", "active" => true)
    json_post "/lab/admin/instruments", payload.merge(name: "Outro", hl7_equipment_id: "bio-01")
    expect([ response.status, json_body["error"] ]).to eq([ 422, "duplicate_hl7_equipment_id" ])
    json_post "/lab/admin/instruments", payload.merge(hl7_equipment_id: "BIO-02")
    expect(json_body["error"]).to eq("duplicate_name")
    json_post "/lab/admin/instruments", payload.merge(name: "", hl7_equipment_id: nil)
    expect(json_body["error"]).to eq("invalid_name")
    json_post "/lab/admin/instruments", payload.merge(name: "X", sector: "radiology", hl7_equipment_id: nil)
    expect(json_body["error"]).to eq("invalid_sector")
    json_post "/lab/admin/instruments", payload.merge(name: "X", hl7_equipment_id: "BIO 01")
    expect(json_body["error"]).to eq("invalid_instrument")
    json_post "/lab/admin/instruments", payload.merge(name: "X", hl7_equipment_id: "A" * 51)
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_instrument" ])
    json_post "/lab/admin/instruments", payload.merge(name: "Y", hl7_equipment_id: "B" * 50)
    expect(response).to have_http_status(:created)
    json_patch "/lab/admin/instruments/#{created['id']}", payload.except(:provider_id).merge(active: false, hl7_equipment_id: nil)
    expect(json_body).to include("active" => false, "hl7_equipment_id" => nil)
    get "/lab/admin/instruments", params: { provider_id: provider.id }
    expect(json_body["instruments"].map { |i| i["name"] }).to eq([ "Analisador bioquímico 1", "Y" ])
  end

  it "D1: /lab/admin/instruments responde para o admin da cidade (não 403)" do
    sign_in_as(admin)
    get "/lab/admin/instruments", params: { provider_id: provider.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["instruments"]).to eq([])
  end

  it "sem step-up 401; sem papel 403; membro lê; quem não é do laboratório não lê" do
    sign_in_as(admin)
    json_post "/lab/admin/instruments", payload
    expect([ response.status, json_body["error"] ]).to eq([ 401, "mfa_required" ])
    qc_instrument!(provider)
    staff = lab_staff!
    sign_in_as(staff)
    json_post "/lab/admin/instruments", payload
    expect(response).to have_http_status(:forbidden)
    get "/lab/instruments", params: { provider_id: provider.id }
    expect(json_body["instruments"].sole).to include("hl7_equipment_id" => "BIO-01", "provider_id" => provider.id)
    sign_in_as(staff_with("recepcao-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier"))
    get "/lab/instruments", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
  end

  it "C13: com os dois interruptores do 21c desligados, aparelhos 403; com só o estoque, respondem" do
    city = City.find(Current.city.id)
    Platform::Features.set!(city: city, key: "lab_quality_control", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(lab_staff!)
    get "/lab/instruments", params: { provider_id: provider.id }
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "lab_quality_control")
    Platform::Features.set!(city: city, key: "lab_inventory", enabled: true, maintainer: ledi_maintainer!)
    get "/lab/instruments", params: { provider_id: provider.id }
    expect(response).to have_http_status(:ok)
  end

  it "C1 e C5: contexto diz de quais laboratórios a sessão é RT/substituto; /lab/exams traz id e componentes" do
    lead = lab_releaser!(provider, lead: true)
    exam = lab_exam!(provider: provider)
    sign_in_as(lead)
    get "/lab/context"
    expect(json_body["technical_lead_of"]).to eq([ provider.id ])
    get "/lab/exams", params: { provider_id: provider.id }
    expect(json_body["exams"].sole).to include("id" => exam.id, "analytes" => [ { "key" => "glicose", "name" => "Glicose" } ])
    sign_in_as(lab_staff!)
    get "/lab/context"
    expect(json_body["technical_lead_of"]).to eq([])
  end

  it "versão do exame ligada a um aparelho do laboratório; aparelho alheio ou inativo recusado" do
    instrument = qc_instrument!(provider)
    other = qc_instrument!(lab_provider!, hl7_equipment_id: "BIO-09")
    exam = lab_exam!(provider: provider)
    base = { method: "Enzimático", material: "Plasma", container: "Tubo cinza", instrument_test_code: "GLI", analytes: LabHelpers::GLUCOSE }
    stepped_up!(admin)
    json_post "/lab/admin/exams/#{exam.id}/versions", base.merge(lab_instrument_id: instrument.id)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("version" => 2, "lab_instrument_id" => instrument.id)
    json_post "/lab/admin/exams/#{exam.id}/versions", base.merge(lab_instrument_id: other.id)
    expect(json_body["error"]).to eq("invalid_version")
    instrument.update!(active: false)
    json_post "/lab/admin/exams/#{exam.id}/versions", base.merge(lab_instrument_id: instrument.id)
    expect(json_body["error"]).to eq("invalid_version")
    json_post "/lab/admin/exams/#{exam.id}/versions", base.merge(lab_instrument_id: nil)
    expect(json_body["lab_instrument_id"]).to be_nil
  end
end
