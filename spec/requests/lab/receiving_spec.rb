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

  it "prazo de coleta novo: a recoleta reagenda o pedido para a data do recebimento" do
    order = req.items.first.exam_order
    sign_in_as(staff)
    travel 1.day do
      json_post "/lab/samples/receive", barcode: sample.barcode, decision: "reject", reason_id: reason.id
      expect(order.reload.scheduled_at).to be_within(1.minute).of(Time.current)
      expect(order.stage_due_on).to be >= Time.zone.today
    end
    expect(order.scheduled_at).to be > 12.hours.from_now - 1.minute
  end

  it "rejeitar amostra sem itens pendentes não cria recoleta" do
    sample.items.update_all(status: "cancelled")
    sign_in_as(staff)
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "reject", reason_id: reason.id
    expect(json_body["sample"]).to include("status" => "rejected")
    expect(json_body["recollection"]).to be_nil
    expect(req.samples.count).to eq(1)
  end

  it "recusas: decisão inválida, motivo inativo ou de outro laboratório, nota longa" do
    sign_in_as(staff)
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "explode"
    expect(json_body["error"]).to eq("invalid_decision")
    reason.update!(active: false)
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "reject", reason_id: reason.id
    expect(json_body["error"]).to eq("reason_required")
    other = LabRejectionReason.create!(exam_provider: lab_provider!, name: "Outro")
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "reject", reason_id: other.id
    expect(json_body["error"]).to eq("reason_required")
    json_post "/lab/samples/receive", barcode: sample.barcode, decision: "accept_with_restriction", restriction_note: "x" * 301
    expect(json_body["error"]).to eq("restriction_note_required")
    expect(sample.reload.status).to eq("awaiting")
  end

  context "requisição coletada na UBS" do
    let(:unit) { create_unit("UBS Recebe").tap { |u| u.update!(collects_samples: true) } }
    let(:nurse) { doctor!(unit) }
    let(:ubs_req) { open_requisition!(provider: provider, exams: [ exam ], unit: unit, place: "ubs", by: nurse) }

    before { Lab::CollectSample.call(sample: ubs_req.samples.first, by: nurse) }

    it "amostra coletada mas fora de remessa não é recebida no laboratório (409)" do
      sign_in_as(staff)
      json_post "/lab/samples/receive", barcode: ubs_req.samples.first.barcode, decision: "accept"
      expect(response).to have_http_status(:conflict)
      expect(json_body).to include("error" => "invalid_transition", "status" => "awaiting")
    end

    it "recoletas: só a coletar e só da UBS; coletada sai da lista; releaser sem papel de recepção não lê" do
      lab_sample = sample
      sign_in_as(staff)
      json_post "/lab/samples/receive", barcode: lab_sample.barcode, decision: "reject", reason_id: reason.id
      sub = ubs_req.samples.first
      sub.update_columns(status: "in_transit")
      json_post "/lab/samples/receive", barcode: sub.barcode, decision: "reject", reason_id: reason.id
      sign_in_as(nurse)
      get "/lab/recollections", params: { origin_unit_id: unit.id }
      expect(json_body["recollections"].map { |r| r["recollection_of_id"] }).to eq([ sub.id ])
      Lab::CollectSample.call(sample: LabSample.find_by(recollection_of_id: sub.id), by: nurse)
      get "/lab/recollections", params: { origin_unit_id: unit.id }
      expect(json_body["recollections"]).to eq([])
      sign_in_as(lab_releaser!(provider))
      get "/lab/recollections", params: { origin_unit_id: unit.id }
      expect(response).to have_http_status(:forbidden)
    end

    it "recollections: 403 para quem não é da unidade nem do laboratório; 422 sem unidade" do
      sign_in_as(doctor!(create_unit("UBS Alheia").tap { |u| u.update!(collects_samples: true) }))
      get "/lab/recollections", params: { origin_unit_id: unit.id }
      expect(response).to have_http_status(:forbidden)
      get "/lab/recollections"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]).to eq("filter_required")
    end
  end
end
