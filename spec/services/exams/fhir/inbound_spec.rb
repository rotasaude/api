require "rails_helper"

# Idempotência sob corrida (Review Focus 1; nota da Task 13): duas entregas
# do mesmo identifier passam juntas pela checagem prévia; a segunda serializa
# em order.lock! e recebe :result_already_registered da RegisterResult — a
# entrada devolve o resultado existente (200), não um 409.
RSpec.describe "Exams::Fhir::Inbound — corrida" do
  before { exam_city!(fhir: true) }

  let(:unit) { create_unit("UBS Corrida") }
  let(:doctor) { doctor!(unit) }
  let(:provider) { exam_catalog_item!(sigtap_code: "0202020380", result_fields: []) && exam_provider!(token: ExamHelpers::FAKE_TOKEN) }
  let(:patient) { exam_patient!(exam_seq!).first }
  let(:order) do
    exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: "0202020380").tap do |o|
      Exams::Steps.schedule(order: o, actor_user: doctor, params: { provider_id: provider.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
    end
  end
  let(:resource) do
    JSON.parse(File.read(Rails.root.join("spec/fixtures/exams/diagnostic-report-hemograma.json"))).tap do |r|
      r["basedOn"][0]["identifier"]["value"] = order.short_code
      r["subject"]["identifier"]["value"] = patient.cpf
      r["issued"] = Time.current.iso8601
    end
  end

  # A checagem prévia "não vê" o resultado (como a requisição concorrente que
  # leu antes do commit da primeira); as demais leituras são as reais.
  def blind_precheck!
    calls = 0
    allow(ExamResult).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
      (calls += 1) == 1 ? nil : original.call(*args, **kwargs)
    end
  end

  it "segunda entrega concorrente do mesmo identifier → ok com o mesmo resultado, created: false" do
    first = Exams::Fhir::Inbound.call(provider: provider, resource: resource)
    expect(first.payload[:created]).to be(true)
    blind_precheck!
    second = Exams::Fhir::Inbound.call(provider: provider, resource: resource)
    expect([ second.ok?, second.payload[:created], second.payload[:result].id ]).to eq([ true, false, first.payload[:result].id ])
    expect(ExamResult.count).to eq(1)
  end

  it "concorrente com outro identifier na mesma guia → invalid_transition" do
    Exams::Fhir::Inbound.call(provider: provider, resource: resource)
    blind_precheck!
    other = Exams::Fhir::Inbound.call(provider: provider, resource: resource.merge("identifier" => [ { "value" => "LS-OUTRO" } ]))
    expect([ other.failure?, other.reason ]).to eq([ true, :invalid_transition ])
  end

  it "A36: corrida do mesmo identifier em duas guias (índice único) → identifier_conflict" do
    Exams::Fhir::Inbound.call(provider: provider, resource: resource)
    second = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: "0202020380")
    Exams::Steps.schedule(order: second, actor_user: doctor, params: { provider_id: provider.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
    other = resource.deep_dup.tap { |r| r["basedOn"][0]["identifier"]["value"] = second.short_code }
    blind_precheck!
    conflict = Exams::Fhir::Inbound.call(provider: provider, resource: other)
    expect([ conflict.failure?, conflict.reason ]).to eq([ true, :identifier_conflict ])
    expect([ second.reload.status, ExamResult.count ]).to eq([ "scheduled", 1 ])
  end
end
