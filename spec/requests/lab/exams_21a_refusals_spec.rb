require "rails_helper"

# Contrato §9 + Desvio 16: laboratório municipal não recebe resultado pelo
# portal, pelo FHIR nem pela unidade — só pela liberação.
RSpec.describe "21a recusa resultado de laboratório municipal", type: :request do
  before { lab_city!(hl7: true) }

  let(:unit) { create_unit("UBS Recusa") }
  let(:doctor) { doctor!(unit) }
  let(:item) { exam_catalog_item!(sigtap_code: "0202010503") }
  let(:lab) { exam_provider!(token: ExamHelpers::FAKE_TOKEN, uses_municipal_lab: true).tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) } }
  let(:order) do
    exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor).tap do |o|
      Exams::Steps.schedule(order: o, actor_user: doctor, params: { provider_id: lab.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
    end
  end

  it "portal, unidade e FHIR: 422 provider_uses_municipal_lab" do
    Platform::Features.set!(city: City.find(Current.city.id), key: "exam_fhir_inbound", enabled: true, maintainer: ledi_maintainer!)
    portal = staff_with("portal-#{SecureRandom.hex(2)}@lab.gov.br", "exam_provider").tap { |u| ExamProviderUser.create!(user: u, exam_provider: lab) }
    sign_in_as(portal)
    json_post "/exams/provider/orders/#{order.id}/result", upload_id: pdf_file!(user: portal).id, released_on: Time.zone.today.iso8601,
                                                           laboratory_name: "Lab", critical: false, values: []
    expect([ response.status, json_body["error"] ]).to eq([ 422, "provider_uses_municipal_lab" ])
    sign_in_as(staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier"))
    json_post "/exams/orders/#{order.id}/result", upload_id: SecureRandom.uuid, released_on: Time.zone.today.iso8601,
                                                  laboratory_name: "Lab", critical: false, values: []
    expect(json_body["error"]).to eq("provider_uses_municipal_lab")
    post "/fhir/DiagnosticReport", params: { resourceType: "DiagnosticReport" }.to_json,
                                   headers: { "CONTENT_TYPE" => "application/fhir+json", "Authorization" => "Bearer #{ExamHelpers::FAKE_TOKEN}" }
    expect([ response.status, json_body["error"] ]).to eq([ 422, "provider_uses_municipal_lab" ])
    expect(ExamResult.count).to eq(0)
  end
end
