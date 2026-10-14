require "rails_helper"
require "json_schemer"

# A42: o regulador (exam_regulator; municipal_admin na fila de regulação) vê
# cid10_justification na fila e no detalhe; requester.cns fica fora da visão
# administrativa; recepção, unidade e prestador seguem sem CID e sem CNS.
RSpec.describe "Exames — CID para o regulador (A42)", type: :request do
  before { exam_city! }

  let(:unit) { create_unit("UBS CID") }
  let(:doctor) { doctor!(unit) }
  let(:schema) { JSONSchemer.schema(Rails.root.join("spec/fixtures/exams/exam-order-v1.json")) }
  let(:order) do
    exam_catalog_item!(requires_authorization: true)
    result = Exams::Open.call(patient: exam_patient!(exam_seq!).first, sigtap_code: "0202010503", priority: "routine", unit: unit,
                              origin: "pec", requester_user: doctor, created_by: doctor, cid10: "D649",
                              requester_cns: Professionals::Cns.generate("cid"))
    raise "pedido recusado: #{result.reason}" if result.failure?

    result.payload.fetch(:order)
  end

  def queue_item = json_body["orders"].find { |o| o["id"] == order.id }

  it "exam_regulator: a fila e o detalhe trazem o CID; o CNS continua nulo" do
    order
    sign_in_as(staff_with("reg-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator"))
    get "/exams/regulation/queue"
    expect(queue_item).to include("cid10_justification" => "D649")
    expect(queue_item["requester"]["cns"]).to be_nil
    expect(schema.valid?(queue_item)).to be(true)
    get "/exams/orders/#{order.id}"
    expect(json_body).to include("cid10_justification" => "D649")
    expect(json_body["requester"]["cns"]).to be_nil
    expect(schema.valid?(json_body)).to be(true)
  end

  it "municipal_admin na fila de regulação: CID, sem CNS" do
    order
    sign_in_as(staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin"))
    get "/exams/regulation/queue"
    expect(queue_item).to include("cid10_justification" => "D649")
    expect(queue_item["requester"]["cns"]).to be_nil
  end

  it "profissional da unidade sem leitura clínica (visão administrativa): nem CID nem CNS" do
    order
    sign_in_as(doctor!(unit))
    get "/exams/orders/#{order.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["events"]).to be_present
    expect(json_body["cid10_justification"]).to be_nil
    expect(json_body["requester"]["cns"]).to be_nil
  end

  it "recepção: nem CID nem CNS no detalhe" do
    order
    sign_in_as(staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier"))
    get "/exams/orders/#{order.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["cid10_justification"]).to be_nil
    expect(json_body["requester"]["cns"]).to be_nil
  end
end
