require "rails_helper"

# Contrato §7: o que o laboratório (e o fake-lab) usa para saber o que fazer.
RSpec.describe "FHIR — ServiceRequest", type: :request do
  before { exam_city!(fhir: true) }

  it "Bundle searchset com as guias agendadas ou coletadas do prestador do token, e só dele" do
    unit = create_unit("UBS SR")
    doctor = doctor!(unit)
    exam_catalog_item! # antes dos prestadores: items: :all os habilita
    provider = exam_provider!(token: ExamHelpers::FAKE_TOKEN)
    other = exam_provider!(name: "Outro")
    patient, = exam_patient!(exam_seq!)
    mine = exam_order!(patient: patient, unit: unit, requester: doctor, priority: "urgent")
    theirs = exam_order!(patient: patient, unit: unit, requester: doctor)
    waiting = exam_order!(patient: patient, unit: unit, requester: doctor)
    [ [ mine, provider ], [ theirs, other ] ].each do |order, prov|
      Exams::Steps.schedule(order: order, actor_user: doctor, params: { provider_id: prov.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
    end
    get "/fhir/ServiceRequest", params: { status: "active" }, headers: { "Authorization" => "Bearer #{ExamHelpers::FAKE_TOKEN}" }
    expect(response.media_type).to eq("application/fhir+json")
    bundle = JSON.parse(response.body)
    expect(bundle.slice("resourceType", "type", "total")).to eq("resourceType" => "Bundle", "type" => "searchset", "total" => 1)
    resource = bundle["entry"].first["resource"]
    expect(resource).to include("resourceType" => "ServiceRequest", "status" => "active", "intent" => "order", "priority" => "urgent")
    expect(resource["identifier"].first["value"]).to eq(mine.short_code)
    expect(resource.dig("code", "coding", 0, "code")).to eq(mine.sigtap_code)
    expect(resource.dig("subject", "identifier")).to eq("system" => Exams::Fhir::Identifiers::CPF_SYSTEM, "value" => patient.cpf)
    expect(response.body).not_to include(theirs.short_code, waiting.short_code)
    get "/fhir/ServiceRequest", params: { status: "completed" }, headers: { "Authorization" => "Bearer #{ExamHelpers::FAKE_TOKEN}" }
    expect([ response.status, JSON.parse(response.body)["error"] ]).to eq([ 422, "invalid_search" ])
  end

  it "sem token válido → 401; interruptor desligado → 403" do
    exam_provider!(token: ExamHelpers::FAKE_TOKEN)
    get "/fhir/ServiceRequest", params: { status: "active" }, headers: { "Authorization" => "Bearer nao-existe-0123456789abcdef0123456789abcd" }
    expect([ response.status, JSON.parse(response.body)["error"] ]).to eq([ 401, "invalid_token" ])
    Platform::Features.set!(city: Current.city, key: "exam_fhir_inbound", enabled: false, maintainer: ledi_maintainer!)
    get "/fhir/ServiceRequest", params: { status: "active" }, headers: { "Authorization" => "Bearer #{ExamHelpers::FAKE_TOKEN}" }
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "exam_fhir_inbound" } ])
  end
end
