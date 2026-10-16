require "rails_helper"

# Spec §5.9 e contrato §5/§9: retificação só por laudo novo com motivo e
# contatos; o anterior fica `rectified`; no 21a o resultado é substituído,
# o exame volta à ciência; o cidadão vê só o vigente; o profissional, os dois.
# B42: só itens do laudo; B51: valor retificado crítico pede aviso novo; os
# filtros de motivo e contatos vêm antes do TOTP (o código não é queimado).
RSpec.describe "Laboratório — retificação", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    lab_city!
    exam_catalog_item!(sigtap_code: "0202010473", release_policy: "immediate", result_fields: [])
  end

  let(:provider) { lab_provider! }
  let(:lead) { lab_releaser!(provider, lead: true) }
  let(:patient_and_citizen) { exam_patient!(exam_seq!) }
  let(:req) { received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ], patient: patient_and_citizen.first) }
  let(:item) { type!(req.items.first, { glicose: "98" }) }
  let(:order) { item.exam_order }
  let(:schema) { JSONSchemer.schema(Rails.root.join("spec/fixtures/exams/exam-order-v1.json")) }

  it "o que cada um vê depois da retificação" do
    first = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(lead), by: lead).payload[:report]
    Exams::Acknowledge.call(order: order.reload, by: order.requester_user)
    old_pdf = order.reload.result.pdf_file.bytes
    sign_in_as(lead)
    json_post "/lab/results", item_id: item.id, values: [ { analyte_key: "glicose", value: "450" } ]
    expect(response).to have_http_status(:created)
    body = { item_ids: [ item.id ], reason: "Erro de digitação do valor", signature: "advanced",
             contacts: [ { person: "Dra. Helena", channel: "telefone", at: Time.current.iso8601 } ] }
    travel 31.seconds do
      json_post "/lab/reports/#{first.id}/rectify", body.merge(reason: "x", totp: totp_for(lead))
      expect(json_body["error"]).to eq("reason_required")
      json_post "/lab/reports/#{first.id}/rectify", body.merge(contacts: [], totp: totp_for(lead))
      expect(json_body["error"]).to eq("contacts_required")
      json_post "/lab/reports/#{first.id}/rectify", body.merge(contacts: [ { person: "X", channel: "pombo", at: Time.current.iso8601 } ], totp: totp_for(lead))
      expect(json_body["error"]).to eq("contacts_required")
    end
    travel 62.seconds do
      json_post "/lab/reports/#{first.id}/rectify", body.merge(totp: totp_for(lead))
    end
    expect(response).to have_http_status(:created)
    expect(json_body).to include("version" => 2, "replaces_report_id" => first.id, "status" => "released", "item_ids" => [ item.id ])
    expect(first.reload.status).to eq("rectified")
    second = LabReport.find(json_body["id"])
    expect(second.content_data).to include("rectification_reason" => "Erro de digitação do valor", "replaces_report_id" => first.id)
    expect(JSON.parse(second.rectification_contacts).sole).to include("person" => "Dra. Helena", "channel" => "telefone")
    expect(DomainEvent.where(name: "lab_report.rectified").sole.payload).to eq("lab_report_id" => second.id, "replaces_report_id" => first.id)

    # Laudo já retificado não se retifica de novo.
    travel 93.seconds do
      json_post "/lab/reports/#{first.id}/rectify", body.merge(totp: totp_for(lead))
    end
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "status" => "rectified" } ])

    # B51: o valor retificado crítico é resultado novo e pede aviso novo.
    get "/lab/criticals/unnotified/count"
    expect(json_body).to eq("count" => 1)

    order.reload
    expect(order).to have_attributes(status: "resulted")
    expect(order.result.values_list.sole["value"]).to eq("450")
    expect(order.result).to be_critical

    sign_in_as(order.requester_user)
    get "/exams/orders/#{order.id}"
    expect(schema.validate(json_body).to_a).to be_empty
    expect(json_body).to have_key("gal_requisition")
    expect(json_body["result"]["replaces_result_id"]).to be_present
    # E17: a ciência antiga não vale para o vigente.
    expect(json_body["result"]["acknowledged_at"]).to be_nil
    expect(json_body["superseded_results"].sole).to include("superseded_at" => be_present, "acknowledged_at" => be_present)
    expect(json_body["superseded_results"].sole["values"].sole["value"]).to eq("98")
    expect(json_body["events"].map { |e| e["kind"] }).to include("result_rectified")

    sign_in_citizen(patient_and_citizen.last.phone)
    get "/citizen/exams/#{order.id}/pdf", params: { citizen_id: patient_and_citizen.last.id }
    expect(response.body.b).to eq(order.result.pdf_file.bytes)
    expect(response.body.b).not_to eq(old_pdf)
    get "/citizen/exams/#{order.result.replaces_result_id}/pdf", params: { citizen_id: patient_and_citizen.last.id }
    expect(response).to have_http_status(:not_found)
    get "/citizen/exams", params: { citizen_id: patient_and_citizen.last.id }
    expect(json_body["exams"].size).to eq(1)
  end

  it "só de laudo liberado; itens do laudo; quem não libera 403" do
    report = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(lead), by: lead).payload[:report]
    sign_in_as(lab_staff!)
    json_post "/lab/reports/#{report.id}/rectify", item_ids: [ item.id ], reason: "Erro de digitação", signature: "advanced",
                                                   contacts: [ { person: "X", channel: "telefone", at: Time.current.iso8601 } ]
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    sign_in_as(lead)
    travel 31.seconds do
      json_post "/lab/reports/#{report.id}/rectify", item_ids: [ SecureRandom.uuid ], reason: "Erro de digitação", signature: "advanced",
                                                     contacts: [ { person: "X", channel: "telefone", at: Time.current.iso8601 } ], totp: totp_for(lead)
      expect(json_body["error"]).to eq("invalid_transition")
      # A recusa dos itens veio antes do TOTP: o mesmo código ainda vale.
      json_post "/lab/reports/#{report.id}/rectify", item_ids: [ item.id ], reason: "Erro de digitação", signature: "advanced",
                                                     contacts: [ { person: "X", channel: "telefone", at: Time.current.iso8601 } ], totp: totp_for(lead)
    end
    expect(response).to have_http_status(:created)
    expect(report.reload.status).to eq("rectified")
  end
end
