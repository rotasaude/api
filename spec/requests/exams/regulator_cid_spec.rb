require "rails_helper"
require "json_schemer"

# A42: o regulador (exam_regulator; municipal_admin na fila de regulação) vê
# cid10_justification na fila e no detalhe; requester.cns fica fora da visão
# administrativa; recepção, unidade e prestador seguem sem CID e sem CNS.
RSpec.describe "Exames — CID para o regulador (A42)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

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

  it "municipal_admin: o detalhe também traz o CID (o papel decide)" do
    order
    sign_in_as(staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin"))
    get "/exams/orders/#{order.id}"
    expect(json_body).to include("cid10_justification" => "D649")
    expect(json_body["requester"]["cns"]).to be_nil
  end

  it "regulador que também é recepção ou profissional vinculado à unidade: CID no detalhe" do
    order
    both = staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator", "citizen_verifier")
    sign_in_as(both)
    get "/exams/orders/#{order.id}"
    expect(json_body).to include("cid10_justification" => "D649")
    expect(json_body["requester"]["cns"]).to be_nil

    linked = doctor!(unit)
    Membership.create!(user: linked, role: "exam_regulator", granted_at: Time.current)
    sign_in_as(linked)
    get "/exams/orders/#{order.id}"
    expect(json_body).to include("cid10_justification" => "D649")
    expect(json_body["requester"]["cns"]).to be_nil
  end

  it "a lista de atrasados da cidade segue sem CID, para regulador e admin" do
    late = travel_to(20.days.ago) { order }
    %w[exam_regulator municipal_admin].each do |role|
      sign_in_as(staff_with("#{role[0, 3]}-#{SecureRandom.hex(2)}@cidade.gov.br", role))
      get "/exams/orders", params: { overdue: "true" }
      expect(response).to have_http_status(:ok)
      expect(json_body["orders"].map { |o| o["id"] }).to eq([ late.id ])
      expect(json_body["orders"].first["overdue"]).to be_present
      expect(json_body["orders"].first["cid10_justification"]).to be_nil
      expect(json_body["orders"].first["requester"]["cns"]).to be_nil
    end
  end

  it "autorizar e negar respondem com o CID" do
    order
    provider = exam_provider!.tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: ExamCatalogItem.first) }
    sign_in_as(staff_with("reg-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator"))
    json_post "/exams/orders/#{order.id}/authorize", provider_id: provider.id
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("cid10_justification" => "D649")
    expect(json_body["requester"]["cns"]).to be_nil
  end

  it "negar responde com o CID" do
    order
    sign_in_as(staff_with("reg-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator"))
    json_post "/exams/orders/#{order.id}/deny", reason: "Sem indicação clínica"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("cid10_justification" => "D649", "status" => "denied")
    expect(json_body["requester"]["cns"]).to be_nil
  end

  it "o portal do prestador (lista) nunca traz o CID nem o CNS" do
    order
    lab = exam_provider!(name: "Lab CID")
    lab_user = staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider").tap { |u| ExamProviderUser.create!(exam_provider: lab, user: u) }
    ExamProviderItem.find_or_create_by!(exam_provider: lab, exam_catalog_item: ExamCatalogItem.first)
    sign_in_as(staff_with("reg-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator"))
    json_post "/exams/orders/#{order.id}/authorize", provider_id: lab.id
    expect(response).to have_http_status(:ok)
    sign_in_as(lab_user)
    json_post "/exams/provider/orders/#{order.id}/schedule", scheduled_at: 2.days.from_now.iso8601, scheduled_place: "Lab CID"
    expect(response).to have_http_status(:ok)
    get "/exams/provider/orders"
    expect(response).to have_http_status(:ok)
    expect(json_body["orders"].map { |o| o["id"] }).to eq([ order.id ])
    expect(json_body["orders"].first).not_to have_key("cid10_justification")
    expect(response.body).not_to include("D649")
    expect(response.body).not_to include(order.requester_cns)
  end
end
