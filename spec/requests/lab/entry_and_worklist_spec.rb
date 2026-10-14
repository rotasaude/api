require "rails_helper"
require "pdf/reader"

# Contrato §5 com dashboard D7/D8: mapa por setor e bancada (sem valor, sem
# trilha); digitação lê a faixa já escolhida e grava trilha; escolha da repetição.
RSpec.describe "Laboratório — mapa e digitação", type: :request do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:glucose) { lab_exam!(provider: provider).tap { |e| e.update!(bench: "Bancada 1") } }
  let(:staff) { lab_staff! }
  let(:req) { received_requisition!(provider: provider, exams: [ glucose ]) }
  let(:item) { req.items.first }

  it "mapa por setor e bancada; PDF; filtros pendentes e urgência" do
    req
    sign_in_as(staff)
    expect { get "/lab/worklists", params: { provider_id: provider.id, pending: "true" } }
      .not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
    group = json_body["groups"].sole
    expect(group).to include("sector" => "biochemistry", "bench" => "Bancada 1")
    expect(group["items"].sole).to include("item_id" => item.id, "requisition_number" => req.number, "label" => "Glicose", "urgent" => false)
    get "/lab/worklists", params: { provider_id: provider.id, urgent: "true" }
    expect(json_body["groups"]).to eq([])
    get "/lab/worklists.pdf", params: { provider_id: provider.id }
    expect(PDF::Reader.new(StringIO.new(response.body)).pages.first.text).to include("Bancada 1", req.number, "Glicose")
  end

  it "digitação pelo item e pela etiqueta; trilha na leitura; escolha só do liberador" do
    sign_in_as(staff)
    expect { get "/lab/entry", params: { item_id: item.id } }.to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    entry = json_body["items"].sole
    expect(entry["analytes"].sole).to include("key" => "glicose", "reference" => { "low" => 70.0, "high" => 99.0, "text" => nil },
                                              "entry_max" => 1500.0, "critical_high" => 400.0, "formula" => nil)
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload).to include("access" => "lab_report", "lab_requisition_id" => req.id)
    json_post "/lab/results", item_id: item.id, values: [ { analyte_key: "glicose", value: "450" } ]
    expect(json_body["results"].sole).to include("value" => "450", "flag" => "critical_high", "source" => "typed", "chosen" => false)
    json_post "/lab/results", barcode: req.samples.first.barcode, sigtap_code: "0202010473", values: [ { analyte_key: "glicose", value: "98" } ]
    expect(json_body["results"].size).to eq(2)
    first_id = json_body["results"].first["id"]
    json_post "/lab/results/#{first_id}/choose"
    expect(json_body["error"]).to eq("missing_role")
    sign_in_as(lab_releaser!(provider))
    json_post "/lab/results/#{first_id}/choose"
    expect(json_body).to include("value" => "450", "chosen" => true)
    expect(Lab::Effective.rows(item.reload)["glicose"].value).to eq("450")
    sign_in_as(doctor!(req.origin_unit))
    get "/lab/entry", params: { item_id: item.id }
    expect(response).to have_http_status(:forbidden)
  end

  it "componente repetido na mesma entrada: 422 invalid_values com a chave (E5)" do
    sign_in_as(staff)
    json_post "/lab/results", item_id: item.id, values: [ { analyte_key: "glicose", value: "90" }, { analyte_key: "glicose", value: "91" } ]
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_values", "analyte_key" => "glicose")
    expect(item.results.count).to eq(0)
  end

  it "por etiqueta sem sigtap_code lista só os itens da amostra, com uma trilha (B39)" do
    sign_in_as(staff)
    barcode = req.samples.first.barcode
    expect { get "/lab/entry", params: { barcode: barcode } }.to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    expect(json_body["items"]).to eq([ { "item_id" => item.id, "sigtap_code" => "0202010473", "name" => "Glicose", "status" => "pending" } ])
    get "/lab/entry", params: { barcode: "0000000000" }
    expect(response).to have_http_status(:not_found)
    get "/lab/entry", params: { barcode: barcode, sigtap_code: "0202010473" }
    expect(json_body["items"].sole).to include("item_id" => item.id, "analytes" => be_present)
  end

  it "escolher repetição já avisada não pede aviso de novo (L9)" do
    sign_in_as(staff)
    json_post "/lab/results", item_id: item.id, values: [ { analyte_key: "glicose", value: "450" } ]
    critical = json_body["results"].sole
    expect(critical["notified"]).to eq(false)
    LabCriticalNotice.create!(lab_result_id: critical["id"], channel: "telefone", notified_at: Time.current, notified_person: "Dra. Ana",
                              notified_role: "médica", recorded_by_user: staff)
    json_post "/lab/results", item_id: item.id, values: [ { analyte_key: "glicose", value: "98" } ]
    sign_in_as(lab_releaser!(provider))
    json_post "/lab/results/#{critical['id']}/choose"
    expect(json_body).to include("chosen" => true, "flag" => "critical_high", "notified" => true, "effective" => true)
  end

  it "mapa só para a equipe daquele laboratório: admin e UBS levam 403 (I2)" do
    req
    sign_in_as(lab_admin!)
    get "/lab/worklists", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    get "/lab/worklists.pdf", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    sign_in_as(doctor!(req.origin_unit))
    get "/lab/worklists", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    get "/lab/worklists.pdf", params: { provider_id: provider.id }
    expect(response).to have_http_status(:forbidden)
    sign_in_as(lab_releaser!(provider))
    get "/lab/worklists", params: { provider_id: provider.id }
    expect(response).to have_http_status(:ok)
  end

  it "POST por etiqueta sem sigtap_code: 422 (B16)" do
    sign_in_as(staff)
    json_post "/lab/results", barcode: req.samples.first.barcode, values: [ { analyte_key: "glicose", value: "90" } ]
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "choose de calculado: 422 unknown_analyte e resposta do choose com effective fresco" do
    lipids = lab_exam!(provider: provider, sigtap_code: "0202010295", name: "Perfil lipídico", analytes: LabHelpers::LIPIDS,
                       material: "Soro", container: "Tubo amarelo (gel)", instrument_test_code: "LIP")
    lipid_item = received_requisition!(provider: provider, exams: [ lipids ]).items.first
    type!(lipid_item, { ct: 200, hdl: 50, tg: 150 })
    type!(lipid_item, { hdl: 60 })
    ldl_old = lipid_item.results.where(analyte_key: "ldl").first
    sign_in_as(lab_releaser!(provider))
    json_post "/lab/results/#{ldl_old.id}/choose"
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to include("error" => "unknown_analyte", "analyte_key" => "ldl")
    hdl_old = lipid_item.results.where(analyte_key: "hdl").first
    json_post "/lab/results/#{hdl_old.id}/choose"
    expect(json_body).to include("analyte_key" => "hdl", "value" => "50", "effective" => true)
  end
end
