require "rails_helper"

# Contrato §4 (F-21.17): a UBS monta a remessa pelas etiquetas, informa a
# temperatura e envia; o laboratório confere lendo as etiquetas; a lida fica
# em trânsito até a decisão, a não lida vira not_received e aparece para a UBS.
RSpec.describe "Laboratório — remessa", type: :request do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:exam) { lab_exam!(provider: provider) }
  let(:unit) { create_unit("UBS Remessa").tap { |u| u.update!(collects_samples: true) } }
  let(:nurse) { doctor!(unit) }
  let(:reqs) { Array.new(2) { open_requisition!(provider: provider, exams: [ exam ], unit: unit, place: "ubs", by: nurse) } }
  let(:barcodes) { reqs.map { |r| r.samples.first.barcode } }

  before { reqs.each { |r| Lab::CollectSample.call(sample: r.samples.first, by: nurse) } }

  it "monta, envia, confere com uma faltando; a UBS vê a não recebida" do
    sign_in_as(nurse)
    json_post "/lab/shipments", origin_unit_id: unit.id, provider_id: provider.id, barcodes: barcodes, temperature_celsius: 4.5
    expect(response).to have_http_status(:created)
    shipment = json_body
    expect(shipment).to include("status" => "open", "temperature_celsius" => 4.5)
    expect(shipment["samples"].map { |s| s["barcode"] }).to match_array(barcodes)
    json_post "/lab/shipments", origin_unit_id: unit.id, provider_id: provider.id, barcodes: [ barcodes.first ], temperature_celsius: 4
    expect(json_body).to eq("error" => "sample_in_other_shipment", "barcode" => barcodes.first)
    json_post "/lab/shipments/#{shipment['id']}/send"
    expect(json_body).to include("status" => "sent", "sent_by" => be_present)
    expect(LabSample.where(barcode: barcodes).pluck(:status).uniq).to eq([ "in_transit" ])
    sign_in_as(lab_staff!)
    get "/lab/shipments", params: { provider_id: provider.id, status: [ "sent" ] }
    expect(json_body["shipments"].map { |s| s["id"] }).to eq([ shipment["id"] ])
    json_post "/lab/shipments/#{shipment['id']}/receive", barcodes: [ barcodes.first ]
    expect(json_body["status"]).to eq("received")
    expect(LabSample.find_by(barcode: barcodes.first).status).to eq("in_transit")
    expect(LabSample.find_by(barcode: barcodes.last).status).to eq("not_received")
    json_post "/lab/shipments/#{shipment['id']}/receive", barcodes: []
    expect(response).to have_http_status(:conflict)
    sign_in_as(nurse)
    get "/lab/recollections", params: { origin_unit_id: unit.id }
    expect(json_body["not_received"].sole).to include("barcode" => barcodes.last, "requisition" => include("number" => reqs.last.number))
    expect(json_body["recollections"]).to eq([])
  end

  it "temperatura fora da faixa, amostra não coletada, outra unidade" do
    sign_in_as(nurse)
    json_post "/lab/shipments", origin_unit_id: unit.id, provider_id: provider.id, barcodes: barcodes, temperature_celsius: 90
    expect(json_body["error"]).to eq("invalid_temperature")
    fresh = open_requisition!(provider: provider, exams: [ exam ], unit: unit, place: "ubs", by: nurse)
    json_post "/lab/shipments", origin_unit_id: unit.id, provider_id: provider.id, barcodes: [ fresh.samples.first.barcode ], temperature_celsius: 4
    expect(json_body).to eq("error" => "sample_not_collected", "barcode" => fresh.samples.first.barcode)
    json_post "/lab/shipments", origin_unit_id: unit.id, provider_id: provider.id, barcodes: [], temperature_celsius: 4
    expect(json_body["error"]).to eq("shipment_empty")
    sign_in_as(doctor!(create_unit("UBS Outra").tap { |u| u.update!(collects_samples: true) }))
    json_post "/lab/shipments", origin_unit_id: unit.id, provider_id: provider.id, barcodes: barcodes, temperature_celsius: 4
    expect(json_body["error"]).to eq("missing_role")
  end
end
