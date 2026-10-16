require "rails_helper"

# Ruling I2 da Task 19: retificação com ICP (único caminho do liberador CRM).
# O v2 nasce pending_signature, congela os itens (B54) e o v1 continua
# valendo; assinado pelo 19b, o FinalizeReport marca o v1 `rectified` e o
# 21a recebe o resultado novo (RectifyResult) com o PDF assinado. Falha
# permanente na finalização (B56): v2 withdrawn, itens descongelam, pedido
# document_cancelled, v1 continua released e pode ser retificado de novo.
RSpec.describe "Laboratório — retificação com ICP", type: :request do
  before do
    lab_city!
    stub_psc_mock!(City.find(Current.city.id))
    stub_signer!
  end

  let(:provider) { lab_provider! }
  let(:doctor) do
    lab_releaser!(provider, council: "CRM", lead: true).tap { |u| u.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) }
  end
  let(:req) { received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ]) }
  let(:item) { type!(req.items.first, { glicose: "98" }) }
  let(:order) { item.exam_order }

  def released_v1!
    linked_certificate!(doctor, provider: "simulated", leaf: fake_psc("simulated").leaf(doctor.professional.cpf))
    report = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "icp", totp: nil, by: doctor).payload.fetch(:report)
    sign_document!(report, author: doctor, provider: "simulated")
    expect(report.reload.status).to eq("released")
    report
  end

  def rectify(report)
    json_post "/lab/reports/#{report.id}/rectify", item_ids: [ item.id ], reason: "Erro de digitação do valor", signature: "icp",
                                                   contacts: [ { person: "Dra. Helena", channel: "telefone", at: Time.current.iso8601 } ]
  end

  it "pendente: v1 vale e itens congelados; assinado: v1 rectified e 21a com o resultado novo" do
    v1 = released_v1!
    first = order.reload.result
    type!(item, { glicose: "450" })
    sign_in_as(doctor)
    rectify(v1)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("status" => "pending_signature", "replaces_report_id" => v1.id, "pdf_url" => nil)
    v2 = LabReport.find(json_body["id"])
    expect(v1.reload.status).to eq("released")
    expect(order.reload.result).to eq(first)
    expect(Lab::Frozen.item?([ item.id ])).to be(true)
    rectify(v1)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "status" => "pending_signature" } ])

    signature = sign_document!(v2, author: doctor, provider: "simulated")
    expect(v2.reload).to have_attributes(status: "released", pdf_sha256: Digest::SHA256.hexdigest(signature.signed_pdf_bytes))
    expect(v1.reload.status).to eq("rectified")
    order.reload
    expect(order.status).to eq("resulted")
    expect(order.result).to have_attributes(replaces_result_id: first.id, critical: true, source: "lab")
    expect(order.result.values_list.sole["value"]).to eq("450")
    expect(order.result.pdf_file.bytes).to eq(signature.signed_pdf_bytes)
    expect(DomainEvent.where(name: "lab_report.rectified").sole.payload).to eq("lab_report_id" => v2.id, "replaces_report_id" => v1.id)
    expect(DomainEvent.where(name: "exam_order.result_rectified").count).to eq(1)
  end

  it "falha permanente na finalização (B56): v2 withdrawn, v1 released e retificável de novo" do
    v1 = released_v1!
    first = order.reload.result
    type!(item, { glicose: "450" })
    sign_in_as(doctor)
    rectify(v1)
    v2 = LabReport.find(json_body["id"])
    link = LabReleaser.active.find_by!(user_id: doctor.id, exam_provider_id: provider.id)
    link.update!(ended_at: Time.current)
    Signatures::SignJob.perform_now(city_slug: Current.city.slug, request_id: v2.signature_request.id)

    expect(v2.reload).to have_attributes(status: "withdrawn", released_at: nil, pdf_file_id: nil)
    expect(v2.signature_request).to have_attributes(status: "returned_to_paper", reason_code: "document_cancelled")
    expect(v1.reload.status).to eq("released")
    expect(Lab::Frozen.item?([ item.id ])).to be(false)
    expect(order.reload.results.to_a).to eq([ first ])
    expect(DomainEvent.where(name: "exam_order.result_rectified").count).to eq(0)

    LabReleaser.create!(user: doctor, exam_provider: provider, technical_lead: true, technical_deputy: false)
    rectify(v1)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("status" => "pending_signature", "replaces_report_id" => v1.id, "version" => 3)
  end
end
