require "rails_helper"
require "pdf/reader"

# Contrato §4: comprovante, etiquetas (reimpressão com trilha), coleta por id
# ou por código de barras; no 21a o exame vai a `collected`.
RSpec.describe "Laboratório — etiqueta, comprovante e coleta", type: :request do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:exam) { lab_exam!(provider: provider, delivery_days: 3) }
  let(:staff) { lab_staff! }
  let(:req) { open_requisition!(provider: provider, exams: [ exam ], by: staff) }

  it "comprovante com previsão e preparo; etiquetas e reimpressão com trilha" do
    sign_in_as(staff)
    get "/lab/requisitions/#{req.id}/receipt.pdf"
    expect(response.media_type).to eq("application/pdf")
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join
    expect(text).to include(req.number, provider.name, req.expected_delivery_on.strftime("%d/%m/%Y"), "Glicose")
    get "/lab/requisitions/#{req.id}/labels.pdf", params: { sample_ids: [ req.samples.first.id ] }
    expect(PDF::Reader.new(StringIO.new(response.body)).page_count).to eq(1)
    get "/lab/requisitions/#{req.id}/labels.pdf"
    printed = DomainEvent.where(name: "lab_sample.label_printed").order(:occurred_at, :created_at).map(&:payload)
    expect(printed.map { |p| p["reprint"] }).to eq([ false, true ])
    expect(printed.first.keys).to contain_exactly("lab_sample_id", "lab_requisition_id", "reprint")
    get "/lab/requisitions/#{req.id}/labels.pdf", params: { sample_ids: [ SecureRandom.uuid ] }
    expect(response).to have_http_status(:not_found)
  end

  it "coleta pela etiqueta: quem e quando; 21a coletado; repetir é 409; UBS não coleta amostra do posto do laboratório" do
    sign_in_as(staff)
    json_post "/lab/samples/collect", barcode: req.samples.first.barcode
    expect(json_body).to include("barcode" => req.samples.first.barcode, "status" => "awaiting", "requisition_number" => req.number)
    expect(json_body["collected_at"]).to be_present
    expect(req.items.first.exam_order.reload.status).to eq("collected")
    json_post "/lab/samples/#{req.samples.first.id}/collect"
    expect([ response.status, json_body["error"] ]).to eq([ 409, "invalid_transition" ])
    json_post "/lab/samples/collect", barcode: "0000000000"
    expect(response).to have_http_status(:not_found)
    other = open_requisition!(provider: provider, exams: [ exam ])
    sign_in_as(doctor!(other.origin_unit))
    json_post "/lab/samples/#{other.samples.first.id}/collect"
    expect(json_body["error"]).to eq("missing_role")
  end
end
