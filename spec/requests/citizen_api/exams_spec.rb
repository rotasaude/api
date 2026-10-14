require "rails_helper"

# Contrato §9 com A22/A23/A29/A32 — Review Focus 3: política contornada.
RSpec.describe "Meus exames (cidadão)", type: :request do
  before { exam_city! }

  let(:unit) { create_unit("UBS Cidadão") }
  let(:doctor) { doctor!(unit) }
  let(:patient_and_citizen) { exam_patient!(exam_seq!) }
  let(:patient) { patient_and_citizen.first }
  let(:citizen) { patient_and_citizen.last }

  def resulted(sigtap, policy, critical: false, of: patient)
    exam_catalog_item!(sigtap_code: sigtap, release_policy: policy, result_fields: [])
    order = exam_order!(patient: of, unit: unit, requester: doctor, sigtap_code: sigtap)
    Exams::Steps.schedule(order: order, actor_user: doctor, params: { provider_id: exam_provider!(name: "L#{SecureRandom.hex(2)}").id,
                                                                      scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Rua do Lab, 1" })
    Exams::RegisterResult.call(order: order.reload, source: "unit", file: pdf_file!(user: doctor), released_on: Time.zone.today.iso8601,
                               laboratory_name: "Lab", critical: critical, values: [], by_user: doctor)
    order.reload
  end

  def external!(sigtap, of: patient)
    ExamResult.create!(patient: of, sigtap_code: sigtap, origin: "external", source: "unit",
                       pdf_file: pdf_file!(user: doctor).tap { |f| f.update!(consumed_at: Time.current) }, values: "[]",
                       released_on: Time.zone.today, laboratory_name: "Particular", registered_by_user: doctor)
  end

  def viewed_count = DomainEvent.where(name: "clinical_record.viewed").count

  it "lista andamento e laudo por política; nunca crítico nem motivo; trilha citizen" do
    immediate = resulted("0202020380", "immediate", critical: true)
    hiv = resulted("0202030300", "never_citizen")
    Exams::Acknowledge.call(order: hiv, by: doctor) # A37: retire na unidade só depois da ciência
    exam_catalog_item!(sigtap_code: "0202010503", requires_authorization: true, release_policy: "after_acknowledgement", result_fields: [])
    denied = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: "0202010503")
    ApplicationRecord.transaction do
      denied.lock!
      Exams::Transition.call(order: denied, kind: "denied", actor_user: doctor, reason: "Sem indicação clínica descrita")
    end
    sign_in_citizen(citizen.phone)
    get "/citizen/exams", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:ok)
    exams = json_body["exams"].index_by { |e| e["id"] }
    expect(json_body["verified"]).to be(true)
    expect(exams[immediate.id]).to include("kind" => "order", "label" => "HEMOGRAMA COMPLETO", "status_label" => "Resultado disponível",
                                           "scheduled_place" => "Rua do Lab, 1", "scheduled_at" => immediate.scheduled_at.iso8601,
                                           "requested_at" => immediate.created_at.iso8601)
    expect(exams[immediate.id]["result"]).to eq("available" => true, "pickup_at_unit" => false,
                                                 "released_on" => Time.zone.today.iso8601, "pdf_available" => true)
    expect(exams[hiv.id]["result"]).to eq("available" => false, "pickup_at_unit" => true, "released_on" => nil, "pdf_available" => false)
    expect(exams[hiv.id]["status_label"]).to eq("Retire o resultado na sua unidade")
    expect(exams[denied.id]).to include("status_label" => "Pedido não autorizado — procure sua unidade", "result" => nil)
    expect(exams[immediate.id].keys).to match_array(%w[id kind label status_label requested_at scheduled_at scheduled_place result])
    expect(response.body).not_to include("critical", "Sem indicação", doctor.email_address, "reason", "Lab\"", "values")
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload).to include("access" => "citizen", "user_id" => nil)

    before_pdf = viewed_count
    get "/citizen/exams/#{immediate.id}/pdf", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Content-Disposition"]).to start_with("attachment")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body.b).to eq(ExamHelpers::PDF_BYTES)
    expect(viewed_count).to eq(before_pdf + 1)
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload)
      .to include("access" => "citizen", "user_id" => nil, "exam_result_id" => immediate.result.id, "patient_id" => patient.id)
  end

  it "after_acknowledgement antes da ciência: result null e a etapa anterior; depois, disponível (A23/A29)" do
    pending_ack = resulted("0202010503", "after_acknowledgement", critical: true)
    sign_in_citizen(citizen.phone)
    get "/citizen/exams", params: { citizen_id: citizen.id }
    entry = json_body["exams"].find { |e| e["id"] == pending_ack.id }
    expect(entry).to include("status_label" => "Agendado", "result" => nil)
    expect(response.body).not_to include("Resultado", "critical")

    Exams::Acknowledge.call(order: pending_ack, by: doctor)
    get "/citizen/exams", params: { citizen_id: citizen.id }
    entry = json_body["exams"].find { |e| e["id"] == pending_ack.id }
    expect(entry).to include("status_label" => "Resultado disponível")
    expect(entry["result"]).to include("available" => true, "pdf_available" => true)
    get "/citizen/exams/#{pending_ack.id}/pdf", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:ok)
  end

  it "never_citizen antes da ciência: etapa anterior e result null (A37); catálogo lido uma vez por exame da página" do
    hiv = resulted("0202030300", "never_citizen")
    2.times { resulted("0202020380", "immediate") }
    sign_in_citizen(citizen.phone)
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].include?("exam_catalog_items") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/citizen/exams", params: { citizen_id: citizen.id } }
    expect(json_body["exams"].find { |e| e["id"] == hiv.id }).to include("status_label" => "Agendado", "result" => nil)
    expect(response.body).not_to include("Retire")
    expect(count).to eq(2)
  end

  it "política contornada: never_citizen, sem ciência, de outro telefone, sem resultado, id qualquer — 404 igual e sem trilha (Review Focus 3)" do
    hiv = resulted("0202030300", "never_citizen")
    Exams::Acknowledge.call(order: hiv, by: doctor)
    pending_ack = resulted("0202010503", "after_acknowledgement", critical: true)
    stranger_patient, stranger = exam_patient!(exam_seq!)
    theirs = resulted("0202020380", "immediate", of: stranger_patient)
    theirs_external = external!("0202020380", of: stranger_patient)
    no_result = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: "0202020380")
    hiv_external = external!("0202030300")
    sign_in_citizen(citizen.phone)
    before = viewed_count
    [ hiv.id, hiv.result.id, pending_ack.id, pending_ack.result.id, theirs.id, theirs.result.id, theirs_external.id,
      no_result.id, hiv_external.id, SecureRandom.uuid, "nao-e-uuid" ].each do |id|
      get "/citizen/exams/#{id}/pdf", params: { citizen_id: citizen.id }
      expect([ response.status, response.body ]).to eq([ 404, { error: "not_found" }.to_json ]), id
    end
    expect(viewed_count).to eq(before)

    get "/citizen/exams", params: { citizen_id: stranger.id }
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    get "/citizen/exams/#{theirs.id}/pdf", params: { citizen_id: stranger.id }
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
  end

  it "par declarado: lista vazia com verified false; PDF 403 not_verified, inclusive de resultado externo (contrato §9/A23)" do
    immediate = resulted("0202020380", "immediate")
    external = external!("0202020380")
    declared = Citizen.create!(cpf: "39053344705", phone: citizen.phone, verification_level: "declared")
    sign_in_citizen(citizen.phone)
    before = viewed_count
    get "/citizen/exams", params: { citizen_id: declared.id }
    expect(json_body).to eq("verified" => false, "exams" => [], "next_before" => nil)
    [ immediate.id, external.id ].each do |id|
      get "/citizen/exams/#{id}/pdf", params: { citizen_id: declared.id }
      expect([ response.status, response.body ]).to eq([ 403, { error: "not_verified" }.to_json ]), id
    end
    expect(viewed_count).to eq(before)
  end

  it "resultado externo aparece pela política do exame; paginação; sem sessão 401; interruptor desligado 403" do
    older = resulted("0202020380", "immediate")
    external = external!("0202010503")
    get "/citizen/exams", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:unauthorized)

    sign_in_citizen(citizen.phone)
    get "/citizen/exams", params: { citizen_id: citizen.id, limit: 1 }
    expect(json_body["exams"].map { |e| e["id"] }).to eq([ external.id ])
    expect(json_body["exams"].first).to include("kind" => "external_result", "status_label" => "Resultado disponível",
                                                "scheduled_at" => nil, "scheduled_place" => nil)
    get "/citizen/exams", params: { citizen_id: citizen.id, limit: 1, before: json_body["next_before"] }
    expect(json_body["exams"].map { |e| e["id"] }).to eq([ older.id ])
    expect(json_body["next_before"]).to be_nil
    get "/citizen/exams", params: { citizen_id: citizen.id, before: "x" }
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_cursor" ])

    get "/citizen/exams/#{external.id}/pdf", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:ok)
    Platform::Features.set!(city: Current.city, key: "exam_tracking", enabled: false, maintainer: ledi_maintainer!)
    get "/citizen/exams", params: { citizen_id: citizen.id }
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "exam_tracking")
    get "/citizen/exams/#{external.id}/pdf", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:forbidden)
  end
end
