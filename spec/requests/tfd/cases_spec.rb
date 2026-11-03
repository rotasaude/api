require "rails_helper"

# Módulo 30, Task 9 (ADR 0048; contrato §6; §14 T7, T8, T9, T21; plano,
# Desvios 10–12 e 18): laudo do médico, envio com as recusas todas juntas,
# fila da comissão, "meus pedidos", leitura nominal com trilha, opções e
# pré-preenchimento pela consulta.
RSpec.describe "TFD — laudo", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { transport_city!(tfd: true, billing: true) }
  let(:unit) { create_unit("UBS Laudo") }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { started_consultation!(unit: unit, doctor: doctor, citizen: regulation_patient!(exam_seq!).last) }
  let(:far) { destination!(name: "Londrina", ibge: "4113700", km: 380) }
  let(:report) do
    { sigtap_code: "0301010072", cid10: "N18.5", justification: "Hemodiálise indisponível no município, sem serviço de nefrologia",
      companion_indicated: true, companion_reason: "Paciente idoso", transport_mode: "fleet" }
  end
  let(:case_keys) do
    %w[id patient status requested_by consultation_id regulation_request_id report destination provider appointment_at inpatient
       legs allowances payments accountability events trip_passengers]
  end

  def create_case(**over)
    json_post "/tfd/cases", { patient_id: consultation.patient_id, consultation_id: consultation.id, report: report,
                              destination_id: far.id }.merge(over)
  end

  def viewed = DomainEvent.where(name: "clinical_record.viewed")

  before { sign_in_as(doctor) }

  it "médico cria rascunho a partir da consulta e envia; a lista da comissão não leva CID" do
    create_case
    expect(response).to have_http_status(:created)
    expect(json_body.keys).to include(*case_keys)
    expect(json_body).to include("status" => "draft", "requested_by" => { "name" => doctor.professional.professional_name, "cbo" => "225125" },
                                 "consultation_id" => consultation.id, "trip_passengers" => [])
    expect(json_body["report"]).to include("cid10" => "N185", "sigtap_name" => "CONSULTA MEDICA EM ATENCAO ESPECIALIZADA")
    id = json_body["id"]
    expect(TfdCase.find(id)).to have_attributes(requester_cbo: "225125", requester_user_id: doctor.id)
    expect(DomainEvent.where(name: "tfd.case_created").map(&:payload)).to include(include("tfd_case_id" => id, "user_id" => doctor.id))
    json_post "/tfd/cases/#{id}/submit"
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to include(*case_keys)
    expect(json_body["status"]).to eq("submitted")
    expect(json_body["events"].map { |e| e["kind"] }).to eq(%w[created submitted])
    expect(DomainEvent.where(name: "tfd.case_submitted").map(&:payload)).to include(include("tfd_case_id" => id, "user_id" => doctor.id))
    expect(DomainEvent.where(name: %w[tfd.case_created tfd.case_submitted]).map(&:payload).to_s).not_to include("N185", "Hemodiálise")
    sign_in_as(committee!)
    get "/tfd/cases", params: { status: "submitted" }
    expect(json_body["items"][0].keys).to contain_exactly("id", "patient", "destination", "status", "submitted_at")
    expect(json_body["items"][0]["patient"].keys).to eq([ "display_name" ])
    expect(response.body).not_to include("N185", "Hemodiálise")
  end

  it "recusas do envio todas juntas: abaixo de 50 km, metropolitano, atenção básica, sem CID, justificativa curta" do
    near = destination!(name: "Araucária", ibge: "4101804", km: 27, metropolitan: true)
    create_case(destination_id: near.id, report: report.merge(sigtap_code: "0301010064", cid10: nil, justification: "curta"))
    expect(response).to have_http_status(:created)
    json_post "/tfd/cases/#{json_body['id']}/submit"
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body["problems"].map { |p| p["error"] }).to contain_exactly(
      "distance_below_minimum", "metropolitan_destination", "primary_care_procedure", "cid_required", "justification_required"
    )
    expect(TfdCase.order(:created_at).last.status).to eq("draft")
  end

  it "laudo: CID fora da CID-10 ativa → invalid_cid10; sem consulta nem pedido de regulação → invalid_request consultation_id" do
    create_case(report: report.merge(cid10: "N18.9"))
    expect(json_body).to include("error" => "invalid_cid10", "path" => "report.cid10")
    create_case(consultation_id: nil)
    expect(json_body).to include("error" => "invalid_request", "path" => "consultation_id")
    other = started_consultation!(unit: unit, doctor: doctor, citizen: regulation_patient!(exam_seq!).last)
    create_case(consultation_id: other.id)
    expect(json_body).to include("error" => "invalid_request", "path" => "consultation_id")
    create_case(report: report.merge(transport_mode: "taxi", companion_indicated: "sim"), destination_id: SecureRandom.uuid, extra: 1)
    expect(json_body["problems"].map { |p| p["path"] })
      .to contain_exactly("extra", "destination_id", "report.transport_mode", "report.companion_indicated")
    expect(TfdCase.count).to eq(0)
  end

  it "PATCH substitui o laudo por inteiro; outro autor → 404 (PATCH e envio); só draft/returned; o paciente não muda" do
    create_case
    id = json_body["id"]
    json_patch "/tfd/cases/#{id}", patient_id: consultation.patient_id, consultation_id: consultation.id, destination_id: far.id,
                                   report: report.merge(companion_indicated: false, companion_reason: nil, cid10: "E11.9")
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to include(*case_keys)
    expect(json_body["report"]).to include("companion_indicated" => false, "companion_reason" => nil, "cid10" => "E119")
    expect(TfdCase.find(id).version).to eq(2)
    sign_in_as(doctor!(create_unit("UBS Outra")))
    json_patch "/tfd/cases/#{id}", patient_id: consultation.patient_id, consultation_id: consultation.id, destination_id: far.id, report: report
    expect(response).to have_http_status(:not_found)
    expect(json_body["error"]).to eq("not_found")
    json_post "/tfd/cases/#{id}/submit"
    expect(response).to have_http_status(:not_found)
    expect(TfdCase.find(id).status).to eq("draft")
    sign_in_as(doctor)
    other = started_consultation!(unit: unit, doctor: doctor, citizen: regulation_patient!(exam_seq!).last)
    json_patch "/tfd/cases/#{id}", patient_id: other.patient_id, consultation_id: other.id, destination_id: far.id, report: report
    expect(json_body).to include("error" => "invalid_request", "path" => "patient_id")
    expect(TfdCase.find(id).patient_id).to eq(consultation.patient_id)
    json_post "/tfd/cases/#{id}/submit"
    json_patch "/tfd/cases/#{id}", patient_id: consultation.patient_id, consultation_id: consultation.id, destination_id: far.id, report: report
    expect(json_body["error"]).to eq("invalid_transition")
    expect(TfdCase.find(id).report["cid10"]).to eq("E119")
  end

  it "enfermeiro não pede; leitura nominal só da comissão e do autor, com trilha" do
    sign_in_as(screener!(unit, cbo: "223505"))
    create_case
    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("cbo_not_allowed")
    tfd = tfd_case!(status: "submitted")
    sign_in_as(committee!)
    expect { json_post "/tfd/cases/#{tfd.id}/read" }.to change { viewed.count }.by(1)
    expect(viewed.map(&:payload)).to include(include("patient_id" => tfd.patient_id, "access" => "tfd"))
    expect(json_body.keys).to include(*case_keys)
    expect(json_body["report"]).to include("cid10" => "N185", "justification" => a_string_including("nefrologia"))
    sign_in_as(tfd.requester_user)
    expect { json_post "/tfd/cases/#{tfd.id}/read" }.to change { viewed.count }.by(1)
    expect(response).to have_http_status(:ok)
    sign_in_as(dispatcher!)
    json_post "/tfd/cases/#{tfd.id}/read"
    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("missing_role")
    sign_in_as(doctor)
    expect { json_post "/tfd/cases/#{tfd.id}/read" }.not_to(change { viewed.count })
    expect(response).to have_http_status(:not_found)
  end

  it "a comissão não lê nem lista rascunho" do
    draft = tfd_case!(status: "draft")
    sign_in_as(committee!)
    json_post "/tfd/cases/#{draft.id}/read"
    expect(response).to have_http_status(:not_found)
    get "/tfd/cases"
    expect(json_body["items"]).to eq([])
  end

  it "laudo e paciente nunca saem no log: criação, PATCH, envio e leitura com sucesso" do
    patient = consultation.patient
    expect([ patient.display_name, patient.cpf ]).to all(be_present)
    committee = committee!
    log = capture_log do
      create_case
      expect(response).to have_http_status(:created)
      id = json_body["id"]
      json_patch "/tfd/cases/#{id}", patient_id: patient.id, consultation_id: consultation.id, destination_id: far.id, report: report
      expect(response).to have_http_status(:ok)
      json_post "/tfd/cases/#{id}/submit"
      expect(json_body["status"]).to eq("submitted")
      sign_in_as(committee)
      json_post "/tfd/cases/#{id}/read"
      expect(json_body["report"]).to include("cid10" => "N185", "justification" => a_string_including("nefrologia"))
      expect(json_body["patient"]["display_name"]).to eq(patient.display_name)
    end
    expect(log).to include("/tfd/cases")
    expect(log).not_to include("N185", "N18.5", "nefrologia", "Hemodiálise", "Paciente idoso", "0301010072",
                               patient.display_name, patient.cpf)
  end

  it "fila da comissão do mais antigo para o mais novo, em páginas com next_before" do
    stub_const("Tfd::CasesController::PAGE", 2)
    cases = Array.new(3) { |i| travel_to(Time.current - (3 - i).hours) { tfd_case!(status: "submitted") } }
    sign_in_as(committee!)
    get "/tfd/cases"
    expect(json_body["items"].map { |i| i["id"] }).to eq(cases.first(2).map(&:id))
    get "/tfd/cases", params: { before: json_body["next_before"] }
    expect(json_body).to match("items" => [ include("id" => cases.last.id) ], "next_before" => nil)
    get "/tfd/cases", params: { before: "lixo" }
    expect(json_body["error"]).to eq("invalid_cursor")
    get "/tfd/cases", params: { status: "draft" }
    expect(json_body).to include("error" => "invalid_request", "path" => "status")
    sign_in_as(doctor)
    get "/tfd/cases"
    expect(json_body["error"]).to eq("missing_role")
  end

  it "meus pedidos: o autor vê o rascunho e o devolvido, não o de outro médico; sem dado clínico" do
    create_case
    draft_id = json_body["id"]
    create_case
    returned_id = json_body["id"]
    json_post "/tfd/cases/#{returned_id}/submit"
    returned = TfdCase.find(returned_id)
    expect(Tfd::Transition.call(tfd_case: returned, to: "returned", by: committee!, reason: "Faltou o exame de creatinina")).to be_ok
    others = tfd_case!(status: "submitted")
    get "/tfd/my_cases"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].map { |i| i["id"] }).to contain_exactly(draft_id, returned_id)
    expect(json_body["items"].map { |i| i["id"] }).not_to include(others.id)
    expect(json_body["items"].map { |i| i["status"] }).to contain_exactly("draft", "returned")
    expect(json_body["items"][0].keys).to contain_exactly("id", "patient", "destination", "status", "submitted_at")
    expect(response.body).not_to include("N185", "Hemodiálise", "creatinina")
    sign_in_as(committee!)
    get "/tfd/my_cases"
    expect(json_body["error"]).to eq("missing_role")
  end

  it "opções: destinos ativos, prestadores externos com o município e a distância mínima; médico e comissão" do
    far
    inactive = destination!(name: "Maringá", ibge: "4115200", km: 420)
    inactive.update!(active: false)
    external = external_provider!(name: "Hospital do Rim")
    external.update!(ibge_code: "4113700")
    own_provider!(unit)
    TransportSetting.current.update!(tfd_min_distance_km: 60)
    get "/tfd/options"
    expect(response).to have_http_status(:ok)
    expect(json_body["destinations"]).to eq([ Transport::Json.destination(far) ])
    expect(json_body["providers"]).to eq([ { "id" => external.id, "name" => "Hospital do Rim", "ibge_code" => "4113700" } ])
    expect(json_body["min_distance_km"]).to eq(60)
    sign_in_as(committee!)
    get "/tfd/options"
    expect(response).to have_http_status(:ok)
    sign_in_as(dispatcher!)
    get "/tfd/options"
    expect(json_body["error"]).to eq("missing_role")
  end

  it "pré-preenche pela consulta do autor, sem trilha; consulta de outro → 404" do
    finalized = finalized_consultation!(unit: unit, doctor: doctor, citizen: regulation_patient!(exam_seq!).last,
                                        evaluated_problems: [ { "terminology" => "cid10", "code" => "N185", "action" => "add" } ])
    expect { get "/tfd/prefill", params: { consultation_id: finalized.id } }.not_to(change { viewed.count })
    expect(json_body).to eq("patient_id" => finalized.patient_id, "cid10" => "N185", "sigtap_code" => nil)
    get "/tfd/prefill", params: { consultation_id: consultation.id }
    expect(json_body).to eq("patient_id" => consultation.patient_id, "cid10" => nil, "sigtap_code" => nil)
    sign_in_as(doctor!(create_unit("UBS Vizinha")))
    get "/tfd/prefill", params: { consultation_id: finalized.id }
    expect(response).to have_http_status(:not_found)
  end

  it "pré-preenchimento: problema resolvido na consulta não vira o CID" do
    citizen = regulation_patient!(exam_seq!).last
    first = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                                    evaluated_problems: [ { "terminology" => "cid10", "code" => "N185", "action" => "add" } ])
    problem = PatientProblem.find_by!(patient_id: first.patient_id, terminology: "cid10", code: "N185")
    resolving = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                                        evaluated_problems: [ { "terminology" => "cid10", "code" => "N185", "action" => "resolve",
                                                                "problem_id" => problem.id } ])
    expect(ConsultationProblem.where(consultation_id: resolving.id).pluck(:action, :code)).to eq([ %w[resolve N185] ])
    get "/tfd/prefill", params: { consultation_id: resolving.id }
    expect(json_body).to eq("patient_id" => resolving.patient_id, "cid10" => nil, "sigtap_code" => nil)
  end

  it "tfd desligado → 403 feature_disabled tfd" do
    Platform::Features.set!(city: city, key: "tfd", enabled: false, maintainer: ledi_maintainer!)
    get "/tfd/my_cases"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "tfd")
  end

  it "transporte desligado com tfd ligado → 403 feature_disabled tfd, sem cascata (T21)" do
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    expect(Tfd::Gate.enabled?(city)).to be(true)
    %w[/tfd/cases /tfd/options /tfd/my_cases].each do |path|
      get path
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "tfd")
    end
  end
end

# §14 T8: o laudo também nasce de um pedido de regulação promovido do mesmo
# paciente, sem consulta; e o pré-preenchimento traz o procedimento pedido.
# A cidade da regulação (a SIGTAP ativa dela, com os procedimentos
# reguláveis) com os interruptores do transporte e do TFD.
RSpec.describe "TFD — origem no pedido de regulação", type: :request do
  let!(:city) do
    city = regulation_city!
    %w[sanitary_transport tfd].each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: ledi_maintainer!) }
    TransportSetting.ensure_defaults!
    CityCatalog.reset_cache!
    city
  end
  let(:unit) { create_unit("UBS Regulação TFD") }
  let(:doctor) { doctor!(unit) }
  let(:far) { destination!(name: "Londrina", ibge: "4113700", km: 380) }

  def create_from(request, patient_id: request.patient_id)
    json_post "/tfd/cases", patient_id: patient_id, regulation_request_id: request.id, destination_id: far.id,
                            report: TransportHelpers::TFD_REPORT.merge("cid10" => "I10")
  end

  before { sign_in_as(doctor) }

  it "só com regulation_request_id (promovido, do mesmo paciente) → 201 com o CBO do vínculo 225*" do
    request = regulation_request!(status: "pending", unit: unit, doctor: doctor)
    create_from(request)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("regulation_request_id" => request.id, "consultation_id" => nil,
                                 "requested_by" => include("cbo" => "225125"))
    expect(TfdCase.find(json_body["id"]).requester_cbo).to eq("225125")
  end

  it "pedido em rascunho ou de outro paciente → invalid_request regulation_request_id" do
    draft = regulation_request!(status: "draft", unit: unit, doctor: doctor)
    create_from(draft)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to include("error" => "invalid_request", "path" => "regulation_request_id")
    request = regulation_request!(status: "pending", unit: unit, doctor: doctor)
    create_from(request, patient_id: regulation_patient!(exam_seq!).first.id)
    expect(json_body).to include("error" => "invalid_request", "path" => "regulation_request_id")
    expect(TfdCase.count).to eq(0)
  end

  it "pré-preenche o procedimento pedido na consulta" do
    request = regulation_request!(status: "pending", unit: unit, doctor: doctor, type: "procedure", target_code: "0209010037")
    get "/tfd/prefill", params: { consultation_id: request.consultation_id }
    expect(json_body).to eq("patient_id" => request.patient_id, "cid10" => nil, "sigtap_code" => "0209010037")
  end
end

# ⚠️ da Task 1: o TFD sem o faturamento (sem procedure_billing e sem CID-10 ativa).
RSpec.describe "TFD — laudo sem faturamento", type: :request do
  let!(:city) { transport_city!(tfd: true) }
  let(:unit) { create_unit("UBS Sem BPA") }
  let(:doctor) { doctor!(unit) }

  it "cria, envia e o helper tfd_case! chega a authorized pelos comandos" do
    expect(Billing::Gate.enabled?(city)).to be(false)
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: regulation_patient!(exam_seq!).last)
    sign_in_as(doctor)
    json_post "/tfd/cases", patient_id: consultation.patient_id, consultation_id: consultation.id,
                            destination_id: destination!(name: "Londrina", ibge: "4113700", km: 380).id,
                            report: TransportHelpers::TFD_REPORT.merge("cid10" => "n18.5")
    expect(response).to have_http_status(:created)
    expect(json_body["report"]["cid10"]).to eq("N185")
    json_post "/tfd/cases/#{json_body['id']}/submit"
    expect(json_body["status"]).to eq("submitted")
    authorized = tfd_case!(status: "authorized")
    expect(authorized.status).to eq("authorized")
    expect(authorized.tfd_case_events.map(&:kind)).to eq(%w[created submitted authorized])
    expect(authorized).to have_attributes(requester_cbo: "225125", version: 3)
  end
end
