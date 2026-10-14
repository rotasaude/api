require "rails_helper"

# Spec §5 etapa 6 (F-21.8) — Review Focus 4: ciência por quem não pode.
RSpec.describe "Exames — ciência e fila da equipe", type: :request do
  before { exam_city! }

  let(:unit) { create_unit("UBS Ciência") }
  let(:doctor) { doctor!(unit) }
  let(:nurse) { nurse!(unit).tap { |n| exam_team!(unit, n) } }
  let(:reception) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }

  def resulted!(critical: false)
    order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
    Exams::Steps.schedule(order: order, actor_user: doctor, params: { provider_id: exam_provider!(name: "L#{SecureRandom.hex(2)}").id,
                                                                      scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    Exams::RegisterResult.call(order: order.reload, source: "unit", file: pdf_file!(user: reception), released_on: Time.zone.today.iso8601,
                               laboratory_name: "Lab", critical: critical, values: [], by_user: reception)
    order.reload
  end

  it "pendentes do solicitante; ciência pelo solicitante sem motivo; repetir = 409" do
    order = resulted!
    sign_in_as(doctor)
    get "/exams/acknowledgements/pending"
    expect(json_body["orders"].map { |o| o["id"] }).to eq([ order.id ])
    expect(json_body["denied"]).to eq([])
    expect(json_body["orders"].first["result"]).to include("critical" => false)
    json_post "/exams/orders/#{order.id}/acknowledge"
    expect(json_body["status"]).to eq("acknowledged")
    expect(DomainEvent.where(name: "exam_order.acknowledged").last.payload).to eq("exam_order_id" => order.id, "by_team" => false)
    json_post "/exams/orders/#{order.id}/acknowledge"
    expect([ response.status, json_body["status"] ]).to eq([ 409, "acknowledged" ])
  end

  it "equipe só com o exame escalado e com motivo; outra unidade, recepção e não escalado recusam" do
    calm = resulted!
    critical = resulted!(critical: true)
    sign_in_as(nurse)
    json_post "/exams/orders/#{calm.id}/acknowledge", reason: "Vi o resultado"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_requester" ])
    get "/exams/acknowledgements/team"
    expect(json_body["orders"].map { |o| o["id"] }).to eq([ critical.id ])
    expect(json_body["orders"].first).to include("escalated" => true)
    expect(json_body["orders"].first["result"]).to include("critical" => true) # A31: a fila mostra que é crítico
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload).to include("access" => "team", "exam_order_id" => critical.id)
    json_post "/exams/orders/#{critical.id}/acknowledge"
    expect(json_body["error"]).to eq("reason_required")
    far = doctor!(create_unit("UBS Distante")).tap { |d| exam_team!(d.professional.links.active.first.health_unit, d) }
    sign_in_as(far)
    json_post "/exams/orders/#{critical.id}/acknowledge", reason: "Avaliado"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_in_team" ])
    sign_in_as(reception)
    json_post "/exams/orders/#{critical.id}/acknowledge", reason: "Avaliado"
    expect(response).to have_http_status(:forbidden)
    sign_in_as(nurse)
    json_post "/exams/orders/#{critical.id}/acknowledge", reason: "Paciente contatada; retorno amanhã"
    expect(json_body["status"]).to eq("acknowledged")
    expect(DomainEvent.where(name: "exam_order.acknowledged").last.payload["by_team"]).to be(true)
    expect(critical.reload.events.last).to have_attributes(kind: "acknowledged", reason: "Paciente contatada; retorno amanhã", actor_user_id: nurse.id)
  end

  it "Review Focus 4: médico da equipe de outra unidade, solicitante de outro, sem papel e fila sem equipe recusam" do
    critical = resulted!(critical: true)
    stranger = doctor!(unit) # vínculo na unidade, mas fora da equipe
    sign_in_as(stranger)
    json_post "/exams/orders/#{critical.id}/acknowledge", reason: "Avaliado"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_in_team" ])
    get "/exams/acknowledgements/team"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_in_team" ])
    sign_in_as(reception)
    get "/exams/acknowledgements/pending"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    expect(critical.reload.status).to eq("resulted")
  end

  it "solicitante digitado: ninguém é o solicitante; a equipe dá ciência com motivo" do
    order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
    typed = Exams::Open.call(patient: order.patient, sigtap_code: "0202010503", priority: "routine", unit: unit, origin: "reception_guide",
                             requester_name: "Dr. Externo", requester_cns: Professionals::Cns.generate("y"),
                             guide_file: pdf_file!(user: reception).tap { |f| f.update!(consumed_at: Time.current) },
                             created_by: reception).payload[:order]
    Exams::Steps.schedule(order: typed, actor_user: reception, params: { provider_id: exam_provider!(name: "LT").id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    Exams::RegisterResult.call(order: typed.reload, source: "unit", file: pdf_file!(user: reception), released_on: Time.zone.today.iso8601,
                               laboratory_name: "Lab", critical: false, values: [], by_user: reception)
    sign_in_as(doctor)
    json_post "/exams/orders/#{typed.id}/acknowledge", reason: "Avaliado"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_in_team" ])
    sign_in_as(nurse)
    json_post "/exams/orders/#{typed.id}/acknowledge", reason: "Avaliado pela equipe"
    expect(json_body["status"]).to eq("acknowledged")
  end

  it "A27: baixar o laudo de um resultado de PEDIDO grava exam_result com o exam_order_id real" do
    order = resulted!
    sign_in_as(doctor)
    get "/exams/acknowledgements/pending"
    pdf_url = json_body["orders"].first["result"]["pdf_url"]
    expect { get pdf_url }.to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    expect(response.body.b).to eq(ExamHelpers::PDF_BYTES)
    expect(DomainEvent.where(name: "clinical_record.viewed").map(&:payload).find { |p| p["access"] == "exam_result" })
      .to include( "exam_order_id" => order.id, "exam_result_id" => order.result.id, "user_id" => doctor.id)
  end

  it "a unidade registra o resultado pela rota; o prestador pela dele" do
    order = exam_order!(patient: exam_patient!(95).first, unit: unit, requester: doctor)
    provider = exam_provider!(name: "Lab Portal")
    Exams::Steps.schedule(order: order, actor_user: doctor, params: { provider_id: provider.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    lab = staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider").tap { |u| ExamProviderUser.create!(exam_provider: provider, user: u) }
    sign_in_as(lab)
    json_post "/exams/uploads", content_type: "application/pdf", data: Base64.strict_encode64(ExamHelpers::PDF_BYTES)
    upload = json_body["upload_id"]
    log = capture_log do
      json_post "/exams/provider/orders/#{order.id}/result", upload_id: upload, released_on: Time.zone.today.iso8601,
                                                             laboratory_name: "Lab Portal", critical: false, values: [ { key: "hba1c", value: "6.1" } ]
    end
    expect(json_body["status"]).to eq("resulted")
    expect(json_body.keys).not_to include("result")
    expect(ExamResult.find_by(exam_order_id: order.id))
      .to have_attributes(source: "provider", registered_by_user_id: lab.id, registered_by_provider_id: provider.id) # A35
    expect(order.reload.events.last).to have_attributes(kind: "resulted", actor_user_id: lab.id, actor_provider_id: provider.id)
    expect(log).not_to include("6.1")
    json_post "/exams/provider/orders/#{order.id}/result", upload_id: upload, released_on: Time.zone.today.iso8601,
                                                           laboratory_name: "Lab Portal", critical: false, values: []
    expect([ response.status, json_body["error"] ]).to eq([ 422, "result_already_registered" ])
  end

  # C13/R4: a rota da UNIDADE.
  it "POST /exams/orders/:id/result pela unidade: 201 com source unit; estranho à unidade 403 not_unit_staff" do
    order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
    Exams::Steps.schedule(order: order, actor_user: doctor, params: { provider_id: exam_provider!(name: "LU").id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    stranger = doctor!(create_unit("UBS Estranha"))
    sign_in_as(stranger)
    json_post "/exams/uploads", content_type: "application/pdf", data: Base64.strict_encode64(ExamHelpers::PDF_BYTES)
    alien_upload = json_body["upload_id"]
    json_post "/exams/orders/#{order.id}/result", upload_id: alien_upload, released_on: Time.zone.today.iso8601,
                                                  laboratory_name: "Lab", critical: false, values: []
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_unit_staff" ])
    sign_in_as(reception)
    json_post "/exams/uploads", content_type: "application/pdf", data: Base64.strict_encode64(ExamHelpers::PDF_BYTES)
    upload = json_body["upload_id"]
    json_post "/exams/orders/#{order.id}/result", upload_id: upload, released_on: Time.zone.today.iso8601,
                                                  laboratory_name: "Lab", critical: true, values: [ { key: "hba1c", value: "13.2" } ]
    expect(response).to have_http_status(:created)
    expect(json_body).to include("status" => "resulted", "escalated" => true)
    expect(json_body["result"].keys).not_to include("values", "critical", "pdf_url") # visão administrativa
    expect(ExamResult.find_by(exam_order_id: order.id)).to have_attributes(source: "unit", registered_by_user_id: reception.id, critical: true)
    json_post "/exams/orders/#{order.id}/result", upload_id: upload, released_on: "amanhã", laboratory_name: "Lab", critical: false, values: []
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_released_on" ])
  end

  it "resultado de pedido cancelado: 409 invalid_transition com o status" do
    order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
    Exams::Steps.cancel(order: order, reason: "Feito em outro serviço", actor_user: doctor)
    sign_in_as(reception)
    json_post "/exams/uploads", content_type: "application/pdf", data: Base64.strict_encode64(ExamHelpers::PDF_BYTES)
    json_post "/exams/orders/#{order.id}/result", upload_id: json_body["upload_id"], released_on: Time.zone.today.iso8601,
                                                  laboratory_name: "Lab", critical: false, values: []
    expect([ response.status, json_body["error"], json_body["status"] ]).to eq([ 409, "invalid_transition", "cancelled" ])
    expect(ExamResult.where(exam_order_id: order.id)).to be_empty
  end
end
