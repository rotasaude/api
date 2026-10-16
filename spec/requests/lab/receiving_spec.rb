require "rails_helper"

# Contrato §4 (F-21.17): aceite, aceite com restrição (nota vai ao laudo) e
# rejeição com motivo do cadastro, que cria a recoleta na UBS de origem e
# reabre a coleta no 21a (prazo de coleta recomeça).
RSpec.describe "Laboratório — recebimento", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:exam) { lab_exam!(provider: provider, sigtap_code: "0202010473") }
  let(:staff) { lab_staff! }
  let(:reason) { LabRejectionReason.create!(exam_provider: provider, name: "Amostra hemolisada") }
  let(:req) { open_requisition!(provider: provider, exams: [ exam ], by: staff) }
  let(:sample) { req.samples.first }

  before { Lab::CollectSample.call(sample: sample, by: staff) }

  it "aceita (posto do laboratório): requisição em análise" do
    sign_in_as(staff)
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "accept"
    expect(json_body["sample"]).to include("status" => "received", "requisition_number" => req.number)
    expect(json_body["recollection"]).to be_nil
    expect(req.reload.status).to eq("in_analysis")
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "accept"
    expect(json_body["error"]).to eq("invalid_transition")
  end

  it "aceita com restrição exige nota" do
    sign_in_as(staff)
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "accept_with_restriction"
    expect(json_body["error"]).to eq("restriction_note_required")
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "accept_with_restriction", restriction_note: "Lipemia discreta"
    expect(json_body["sample"]).to include("status" => "accepted_with_restriction", "restriction_note" => "Lipemia discreta")
  end

  it "rejeita: recoleta nova ligada à anterior, itens mudam de amostra, 21a volta a agendado com prazo de coleta novo" do
    order = req.items.first.exam_order
    expect(order.reload.status).to eq("collected")
    sign_in_as(staff)
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "reject"
    expect(json_body["error"]).to eq("reason_required")
    travel 1.day do
      json_post "/lab/samples/receive", barcode: sample.barcode, decision: "reject", reason_id: reason.id
    end
    expect(json_body["sample"]).to include("status" => "rejected", "rejection_reason" => "Amostra hemolisada")
    recollection = json_body["recollection"]
    expect(recollection).to include("status" => "awaiting", "recollection_of_id" => sample.id, "barcode" => "#{req.number}02")
    expect(req.items.first.reload.lab_sample_id).to eq(recollection["id"])
    expect(order.reload).to have_attributes(status: "scheduled", stage: "collect")
    expect(order.events.last).to have_attributes(kind: "scheduled", reason: "recollection")
    expect(DomainEvent.where(name: "lab_sample.rejected").sole.payload.keys).to contain_exactly("lab_sample_id", "lab_requisition_id", "recollection_id")
    json_post "/lab/samples/receive", barcode: "9999999999", decision: "accept"
    expect(response).to have_http_status(:not_found)
  end
    # P16/B16: not_received não é definitivo — o tubo pode chegar depois.
    context "amostra not_received (o tubo chegou depois)" do
      before { sample.update_columns(status: "not_received", lab_shipment_id: nil) }

      it "aceita" do
        sign_in_as(staff)
        json_post "/lab/samples/receive", barcode: sample.barcode, decision: "accept"
        expect(json_body["sample"]).to include("status" => "received")
        expect(req.reload.status).to eq("in_analysis")
      end

      it "rejeita e cria a recoleta" do
        sign_in_as(staff)
        json_post "/lab/samples/receive", barcode: sample.barcode, decision: "reject", reason_id: reason.id
        expect(json_body["sample"]).to include("status" => "rejected")
        expect(json_body["recollection"]).to include("status" => "awaiting", "recollection_of_id" => sample.id)
      end
    end

    it "E7: a 100ª amostra da requisição é recusada com 422 too_many_samples e nada muda" do
      sample.update_columns(barcode: "#{req.number}99")
      sign_in_as(staff)
      json_post "/lab/samples/receive", barcode: sample.reload.barcode, decision: "reject", reason_id: reason.id
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("too_many_samples")
      expect(sample.reload.status).to eq("awaiting")
      expect(req.samples.count).to eq(1)
    end

    it "quem não é do laboratório não recebe" do
      sign_in_as(doctor!(create_unit("UBS X")))
      json_post "/lab/samples/receive", barcode: sample.barcode, decision: "accept"
      expect(response).to have_http_status(:forbidden)
    end
end
