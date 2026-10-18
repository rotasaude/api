require "rails_helper"

# Contrato §3 (F-21.26, parte da bula): material com níveis e analitos;
# lote com um código de barras por nível (único na cidade, nunca só 10
# dígitos); referência da bula versionada; quem configura é o admin ou o
# RT/substituto, com step-up; o interruptor fecha tudo.
RSpec.describe "CIQ — cadastro", type: :request do
  before { qc_city! }

  let(:provider) { lab_provider! }
  let(:instrument) { qc_instrument!(provider) }
  let(:exam) { qc_exam!(provider: provider, instrument: instrument) }
  let(:lipids) { qc_exam!(provider: provider, instrument: instrument, sigtap_code: "0202010295", name: "Lipidograma", analytes: LabHelpers::LIPIDS, instrument_test_code: "LIP") }
  let(:lead) { lab_releaser!(provider, lead: true) }
  let(:material_body) do
    { provider_id: provider.id, name: "Lyphochek Assayed Chemistry Control", manufacturer: "Bio-Rad", levels: [ "Nível 1", "Nível 2" ],
      analytes: [ { lab_exam_id: exam.id, analyte_key: "glicose" } ], active: true }
  end

  def create_material(body = material_body)
    json_post "/lab/qc/materials", body
    json_body
  end

  def create_lot(material_id, codes = { "Nível 1" => "CQB2611N1", "Nível 2" => "CQB2611N2" }, number: "CQB-2611", expires: (Time.zone.today + 300).iso8601)
    json_post "/lab/qc/lots", material_id: material_id, lot_number: number, expires_on: expires, level_barcodes: codes
    json_body
  end

  it "interruptor desligado: 403" do
    Platform::Features.set!(city: City.find(Current.city.id), key: "lab_quality_control", enabled: false, maintainer: ledi_maintainer!)
    stepped_up!(lead)
    get "/lab/qc/materials", params: { provider_id: provider.id }
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "lab_quality_control")
  end

  it "RT cadastra material e lote; recusas de níveis, analitos e códigos" do
    stepped_up!(lead)
    material = create_material
    expect(response).to have_http_status(:created)
    expect(material).to include("levels" => [ "Nível 1", "Nível 2" ], "has_lots" => false,
                                "analytes" => [ { "lab_exam_id" => exam.id, "analyte_key" => "glicose" } ])
    create_material(material_body.merge(levels: [ "Nível 1", "Nível 1" ]))
    expect(json_body["error"]).to eq("invalid_levels")
    create_material(material_body.merge(analytes: [ { lab_exam_id: lipids.id, analyte_key: "ldl" } ]))
    expect(json_body["error"]).to eq("invalid_analytes") # calculado não tem controle próprio

    lot = create_lot(material["id"])
    expect(response).to have_http_status(:created)
    expect(lot).to include("lot_number" => "CQB-2611", "status" => "in_use", "expired" => false, "material_name" => "Lyphochek Assayed Chemistry Control",
                           "level_barcodes" => { "Nível 1" => "CQB2611N1", "Nível 2" => "CQB2611N2" })
    create_lot(material["id"], { "Nível 1" => "CQB2611N1", "Nível 2" => "OUTRO2" }, number: "CQB-2612")
    expect(json_body["error"]).to eq("barcode_taken")
    create_lot(material["id"], { "Nível 1" => "0000012301", "Nível 2" => "OUTRO2" }, number: "CQB-2612")
    expect(json_body["error"]).to eq("barcode_taken") # espaço das amostras
    create_lot(material["id"], { "Nível 1" => "com espaço", "Nível 2" => "OUTRO2" }, number: "CQB-2612")
    expect(json_body["error"]).to eq("invalid_barcode")
    create_lot(material["id"], { "Nível 1" => "OUTRO1" }, number: "CQB-2612")
    expect(json_body["error"]).to eq("invalid_levels")
    create_lot(material["id"], { "Nível 1" => "OUTRO1", "Nível 2" => "OUTRO2" }, number: "CQB-2611")
    expect(json_body["error"]).to eq("duplicate_lot")
    create_lot(material["id"], { "Nível 1" => "OUTRO1", "Nível 2" => "OUTRO2" }, number: "CQB-2612", expires: (Time.zone.today - 1).iso8601)
    expect(json_body["error"]).to eq("expired_lot")

    json_patch "/lab/qc/materials/#{material['id']}", material_body.except(:provider_id).merge(levels: [ "Nível 1", "Nível 2", "Nível 3" ])
    expect(json_body["error"]).to eq("invalid_levels") # já tem lote
    json_patch "/lab/qc/materials/#{material['id']}", material_body.except(:provider_id).merge(name: "Lyphochek (2 níveis)")
    expect(json_body).to include("name" => "Lyphochek (2 níveis)", "has_lots" => true)

    json_post "/lab/qc/lots/#{lot['id']}/close", {}
    expect(json_body).to include("status" => "closed")
    json_post "/lab/qc/lots/#{lot['id']}/close", {}
    expect(response).to have_http_status(:conflict)
    get "/lab/qc/lots", params: { provider_id: provider.id }
    expect(json_body["lots"].map { |l| l["lot_number"] }).to eq([ "CQB-2611" ])
  end

  it "quem configura: admin e RT/substituto com step-up; liberador comum e técnica não" do
    sign_in_as(lead)
    create_material
    expect([ response.status, json_body["error"] ]).to eq([ 401, "mfa_required" ])
    stepped_up!(lab_releaser!(provider))
    create_material
    expect(response).to have_http_status(:forbidden)
    stepped_up!(lab_staff!) # com step-up, para a recusa ser do papel
    create_material
    expect(response).to have_http_status(:forbidden)
    get "/lab/qc/materials", params: { provider_id: provider.id }
    expect(response).to have_http_status(:ok)
    stepped_up!(lab_admin!)
    create_material
    expect(response).to have_http_status(:created)
  end

  it "referência da bula: ponto (vírgula recusada), dp positivo, versões, lote encerrado; evento só com ids" do
    stepped_up!(lead)
    material = create_material
    lot = create_lot(material["id"])
    body = { lot_id: lot["id"], level: "Nível 1", analyte_key: "glicose", instrument_id: instrument.id, mean: "90.5", sd: "4.5" }
    json_post "/lab/qc/targets", body
    expect(response).to have_http_status(:created)
    expect(json_body).to include("version" => 1, "source" => "package_insert", "mean" => "90.5", "sd" => "4.5", "based_on_runs" => nil,
                                 "reason" => nil)
    json_post "/lab/qc/targets", body.merge(mean: "90,5")
    expect(json_body["error"]).to eq("invalid_value")
    json_post "/lab/qc/targets", body.merge(sd: "0")
    expect(json_body["error"]).to eq("invalid_value")
    json_post "/lab/qc/targets", body.merge(level: "Nível 9")
    expect(json_body["error"]).to eq("invalid_levels")
    json_post "/lab/qc/targets", body.merge(analyte_key: "ureia")
    expect(json_body["error"]).to eq("invalid_analytes")
    json_post "/lab/qc/targets", body.merge(instrument_id: qc_instrument!(lab_provider!, hl7_equipment_id: "X1").id)
    expect(json_body["error"]).to eq("invalid_instrument")
    json_post "/lab/qc/targets", body.merge(mean: "91")
    expect(json_body["error"]).to eq("reason_required") # C6: troca da vigente
    json_post "/lab/qc/targets", body.merge(mean: "91", reason: "Bula do lote corrigida pelo fabricante")
    expect(json_body).to include("version" => 2, "reason" => "Bula do lote corrigida pelo fabricante")
    get "/lab/qc/targets", params: { lot_id: lot["id"] }
    expect(json_body["current"].map { |t| [ t["level"], t["version"], t["mean"] ] }).to eq([ [ "Nível 1", 2, "91" ] ])
    expect(json_body["history"].map { |t| t["version"] }).to eq([ 1, 2 ])
    expect(DomainEvent.where(name: "lab_qc_target.accepted").map { |e| e.payload.keys.sort }.uniq).to eq([ %w[lab_qc_target_id source] ])
    json_post "/lab/qc/lots/#{lot['id']}/close", {}
    json_post "/lab/qc/targets", body
    expect(json_body["error"]).to eq("lot_closed")
  end
end
