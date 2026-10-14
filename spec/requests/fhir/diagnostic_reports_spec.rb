require "rails_helper"

# Contrato §7 (com D7 e A7, A15, A35) — F-21.7. Review Focus 1: laudo no
# paciente errado.
RSpec.describe "FHIR — DiagnosticReport de entrada", type: :request do
  before { exam_city!(fhir: true) }

  let(:unit) { create_unit("UBS FHIR") }
  let(:doctor) { doctor!(unit) }
  let(:item) do
    exam_catalog_item!(sigtap_code: "0202020380", result_fields: [
      { "key" => "hb", "label" => "Hemoglobina", "unit" => "g/dL", "loinc" => "718-7" } ])
  end
  let(:provider) { exam_provider!(token: ExamHelpers::FAKE_TOKEN).tap { |p| ExamProviderItem.find_or_create_by!(exam_provider: p, exam_catalog_item: item) } }
  let(:patient_and_citizen) { exam_patient!(exam_seq!) }
  let(:patient) { patient_and_citizen.first }
  let(:order) do
    exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: item.sigtap_code).tap do |o|
      Exams::Steps.schedule(order: o, actor_user: doctor, params: { provider_id: provider.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
    end
  end

  def report(**over)
    base = JSON.parse(File.read(Rails.root.join("spec/fixtures/exams/diagnostic-report-hemograma.json")))
    base["basedOn"][0]["identifier"]["value"] = order.short_code
    base["subject"]["identifier"]["value"] = patient.cpf
    base["issued"] = Time.current.iso8601
    base.merge(over.transform_keys(&:to_s))
  end

  def send_report(body, token: ExamHelpers::FAKE_TOKEN, type: "application/fhir+json")
    post "/fhir/DiagnosticReport", params: body.is_a?(String) ? body : body.to_json,
                                   headers: { "CONTENT_TYPE" => type, "Authorization" => "Bearer #{token}" }
  end

  it "aceita: resultado com LOINC no campo, LOINC desconhecido sem chave, crítico por LL, idempotente" do
    provider
    log = capture_log { send_report(report) }
    expect(response).to have_http_status(:created)
    result = ExamResult.find(json_body["result_id"])
    expect(result).to have_attributes(source: "fhir", critical: true, fhir_identifier: "LS-2026-000123", registered_by_provider_id: provider.id)
    expect(result.values_list.map { |v| v.values_at("key", "loinc", "value") }).to eq([ [ "hb", "718-7", "13.4" ], [ nil, "777-3", "41" ] ])
    expect(order.reload.status).to eq("resulted")
    expect(order.events.where(kind: "escalated").pluck(:escalation_reason)).to eq(%w[critical])
    expect(log).not_to include(patient.cpf, "13.4", ExamHelpers::FAKE_TOKEN, "JVBERi0")
    send_report(report(presentedForm: [ { contentType: "application/pdf", data: Base64.strict_encode64(ExamHelpers::PDF_BYTES + "outro") } ]))
    expect([ response.status, json_body["result_id"] ]).to eq([ 200, result.id ])
    expect(result.reload.pdf_file.bytes).to eq(Base64.strict_decode64(report["presentedForm"][0]["data"]))
  end

  it "A35: o evento resulted pela entrada FHIR tem só o prestador como ator" do
    provider
    send_report(report)
    event = order.reload.events.find_by!(kind: "resulted")
    expect([ event.actor_provider_id, event.actor_user_id ]).to eq([ provider.id, nil ])
  end

  it "paciente e prestador errados (Review Focus 1)" do
    provider
    other_patient, = exam_patient!(exam_seq!)
    send_report(report(subject: { identifier: { system: Exams::Fhir::Identifiers::CPF_SYSTEM, value: other_patient.cpf } }))
    expect([ response.status, json_body["error"] ]).to eq([ 422, "patient_mismatch" ])
    cns = Professionals::Cns.generate("cidada-fhir")
    patient_and_citizen.last.update!(cns: cns)
    send_report(report("identifier" => [ { "value" => "LS-CNS-1" } ],
                       "subject" => { "identifier" => { "system" => Exams::Fhir::Identifiers::CNS_SYSTEM, "value" => cns } }))
    expect(response).to have_http_status(:created)

    second = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: item.sigtap_code)
    intruder = exam_provider!(name: "Intruso", token: "token-do-intruso-0123456789abcdef0123456789")
    Exams::Steps.schedule(order: second, actor_user: doctor, params: { provider_id: provider.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
    body = report("identifier" => [ { "value" => "LS-X" } ])
    body["basedOn"][0]["identifier"]["value"] = second.short_code
    send_report(body, token: "token-do-intruso-0123456789abcdef0123456789")
    expect([ response.status, json_body["error"] ]).to eq([ 404, "order_not_found" ])
    body["basedOn"][0]["identifier"]["value"] = "ZZZZZZZZZZ"
    send_report(body)
    expect([ response.status, json_body["error"] ]).to eq([ 404, "order_not_found" ])
    expect(second.reload.status).to eq("scheduled")
    expect(intruder.reload).to be_present
  end

  it "CNS válido de outra pessoa não passa e nada é guardado" do
    provider
    other_patient, other_citizen = exam_patient!(exam_seq!)
    other_cns = Professionals::Cns.generate("outra-pessoa")
    other_citizen.update!(cns: other_cns)
    send_report(report("subject" => { "identifier" => { "system" => Exams::Fhir::Identifiers::CNS_SYSTEM, "value" => other_cns } }))
    expect([ response.status, json_body["error"] ]).to eq([ 422, "patient_mismatch" ])
    expect(other_patient.id).not_to eq(patient.id)
    expect(order.reload.status).to eq("scheduled")
    expect(ExamFile.count).to eq(0) # recusado antes de guardar o PDF
  end

  it "recusas: token, interruptor, tipo, recurso, PDF, dom-3, status preliminar, transição, taxa" do
    provider
    send_report(report, token: "nao-existe-0123456789abcdef0123456789abcd")
    expect([ response.status, json_body["error"] ]).to eq([ 401, "invalid_token" ])
    send_report(report, type: "application/json")
    expect([ response.status, json_body["error"] ]).to eq([ 415, "unsupported_media_type" ])
    send_report("{nope")
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_resource" ])
    send_report(report.except("presentedForm"))
    expect([ response.status, json_body["error"] ]).to eq([ 422, "missing_pdf" ])
    send_report(report(presentedForm: [ { contentType: "application/pdf", data: Base64.strict_encode64("GIF89a") } ]))
    expect(json_body["error"]).to eq("missing_pdf")
    send_report(report(status: "preliminary"))
    expect([ json_body["error"], json_body["details"] ]).to eq([ "invalid_resource", [ "/status" ] ])
    send_report(report(result: [ { reference: "#hb" } ]))
    expect([ json_body["error"], json_body["details"] ]).to eq([ "invalid_resource", [ "/result" ] ])
    expect(response.body).not_to include(patient.cpf, "13.4")
    Exams::Steps.cancel(order: order, reason: "Paciente desistiu", actor_user: doctor)
    send_report(report)
    expect([ response.status, json_body["error"] ]).to eq([ 409, "invalid_transition" ])
    provider.update!(fhir_token_revoked_at: Time.current)
    send_report(report)
    expect(json_body["error"]).to eq("invalid_token")
    Platform::Features.set!(city: Current.city, key: "exam_fhir_inbound", enabled: false, maintainer: ledi_maintainer!)
    send_report(report)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "exam_fhir_inbound" } ])
  end

  it "recusas do recurso: base64 inválido, bytes que não são PDF, campo obrigatório ausente, data impossível, exemplo dom-3 do contracts" do
    provider
    send_report(report(presentedForm: [ { contentType: "application/pdf", data: "%%%não-é-base64%%%" } ]))
    expect([ response.status, json_body["error"] ]).to eq([ 422, "missing_pdf" ])
    send_report(report(presentedForm: [ { contentType: "application/pdf", data: Base64.strict_encode64("%PDF") } ]))
    expect(json_body["error"]).to eq("missing_pdf")
    send_report(report.except("code", "performer"))
    expect([ json_body["error"], json_body["details"] ]).to eq([ "invalid_resource", [ "/code", "/performer" ] ])
    send_report(report(issued: "2026-13-45T10:00:00Z"))
    expect([ json_body["error"], json_body["details"] ]).to eq([ "invalid_resource", [ "/issued" ] ])
    send_report(report(issued: 2.days.from_now.iso8601))
    expect([ json_body["error"], json_body["details"] ]).to eq([ "invalid_resource", [ "/issued" ] ])
    uncontained = JSON.parse(File.read(Rails.root.join("spec/fixtures/exams/invalid-diagnostic-report-uncontained-observation.json")))
    send_report(report(contained: uncontained["contained"], result: uncontained["result"]))
    expect([ json_body["error"], json_body["details"] ]).to eq([ "invalid_resource", [ "/result" ] ])
    send_report("[1]")
    expect([ json_body["error"], json_body["details"] ]).to eq([ "invalid_resource", [ "" ] ])
    expect(order.reload.status).to eq("scheduled")
    expect(ExamFile.count).to eq(0)
  end

  it "corpo acima de 15 MB → 413; o corpo FHIR não entra em params" do
    provider
    send_report(" " * (15 * 1024 * 1024 + 1))
    expect([ response.status, json_body["error"] ]).to eq([ 413, "payload_too_large" ])
    log = capture_log { send_report(report(status: "preliminary")) }
    expect(log).to include("Processing by Fhir::DiagnosticReportsController#create")
    expect(log).not_to include("resourceType", "presentedForm", patient.cpf, "LS-2026-000123", "Parameters:")
  end

  it "laudo novo para guia que já tem resultado → 409" do
    provider
    send_report(report)
    expect(response).to have_http_status(:created)
    send_report(report("identifier" => [ { "value" => "LS-OUTRO" } ]))
    expect([ response.status, json_body["error"] ]).to eq([ 409, "invalid_transition" ])
  end

  describe "A36: reenvio, correção e código" do
    it "reenvio do mesmo identifier na mesma guia → 200 mesmo com PDF quebrado; em outra guia → 409 identifier_conflict" do
      provider
      send_report(report)
      first_id = json_body["result_id"]
      send_report(report(presentedForm: [ { contentType: "application/pdf", data: Base64.strict_encode64("GIF89a") } ]))
      expect([ response.status, json_body["result_id"] ]).to eq([ 200, first_id ])
      second = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: item.sigtap_code)
      Exams::Steps.schedule(order: second, actor_user: doctor, params: { provider_id: provider.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
      body = report
      body["basedOn"][0]["identifier"]["value"] = second.short_code
      files = ExamFile.count
      send_report(body)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "identifier_conflict" } ])
      expect([ second.reload.status, ExamFile.count ]).to eq([ "scheduled", files ])
    end

    it "status amended → 422 amendment_not_supported, no primeiro envio e no reenvio, sem guardar arquivo" do
      provider
      send_report(report(status: "amended"))
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "amendment_not_supported" } ])
      expect([ order.reload.status, ExamFile.count ]).to eq([ "scheduled", 0 ])
      send_report(report)
      expect(response).to have_http_status(:created)
      send_report(report(status: "amended"))
      expect(json_body["error"]).to eq("amendment_not_supported")
    end

    it "coding SIGTAP diferente do da guia → invalid_resource /code; sem coding SIGTAP passa" do
      provider
      send_report(report(code: { coding: [ { system: Exams::Fhir::ServiceRequests::SIGTAP_SYSTEM, code: "0202010503" } ] }))
      expect([ response.status, json_body["error"], json_body["details"] ]).to eq([ 422, "invalid_resource", [ "/code" ] ])
      expect([ order.reload.status, ExamFile.count ]).to eq([ "scheduled", 0 ])
      send_report(report(code: { coding: [ { system: "http://loinc.org", code: "58410-2" } ] }))
      expect(response).to have_http_status(:created)
    end

    it "PDF acima de 10 MB → missing_pdf" do
      provider
      big = ExamHelpers::PDF_BYTES + ("0" * (Exams::Files::MAX_BYTES + 1 - ExamHelpers::PDF_BYTES.bytesize))
      send_report(report(presentedForm: [ { contentType: "application/pdf", data: Base64.strict_encode64(big) } ]))
      expect([ response.status, json_body["error"] ]).to eq([ 422, "missing_pdf" ])
      expect(ExamFile.count).to eq(0)
    end
  end

  it "limite de 60 por minuto por token" do
    provider
    allow(Fhir::BaseController::RateLimitStore).to receive(:increment).and_return(61)
    send_report(report)
    expect([ response.status, json_body["error"] ]).to eq([ 429, "rate_limited" ])
  end

  it "a chave do limite é o hash do token, nunca o token" do
    provider
    keys = []
    allow(Fhir::BaseController::RateLimitStore).to receive(:increment) { |key, *| keys << key; 1 }
    send_report(report)
    expect(keys.size).to eq(1)
    expect(keys.first).to include(ExamProvider.digest(ExamHelpers::FAKE_TOKEN))
    expect(keys.first).not_to include(ExamHelpers::FAKE_TOKEN)
  end

  it "prestador simulado exige fake_lab" do
    order # agendado antes de o prestador virar simulado (A34 recusaria agendar)
    provider.update!(simulated: true)
    send_report(report)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "fake_lab" } ])
    Platform::Features.set!(city: Current.city, key: "fake_lab", enabled: true, maintainer: ledi_maintainer!)
    send_report(report)
    expect(response).to have_http_status(:created)
  end
end
