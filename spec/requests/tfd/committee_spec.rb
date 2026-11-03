require "rails_helper"

# Módulo 30, Task 10 (ADR 0048; contrato §6; §14 T8, T10, T12, T18, T25;
# plano, Desvios 11–12): a comissão decide (autorizar, devolver, recusar),
# marca o atendimento, registra a internação e cancela — tudo com step-up,
# cada escrita devolvendo o <tfd-case> inteiro.
RSpec.describe "TFD — comissão", type: :request do
  let!(:city) { transport_city!(tfd: true, billing: true) }
  let(:committee) { committee! }
  let(:reason) { "Laudo completo e destino de referência pactuado" }
  let(:appointment_at) { (Time.zone.now + 7.days).change(hour: 9).iso8601 }

  def decide(tfd, decision, text = reason) = json_post("/tfd/cases/#{tfd.id}/decide", { decision: decision, reason: text })
  def set_appointment(tfd, **body) = json_post("/tfd/cases/#{tfd.id}/appointment", { appointment_at: appointment_at }.merge(body))
  def inpatient(tfd, **body) = json_post("/tfd/cases/#{tfd.id}/inpatient", body)
  def cancel(tfd, text = reason) = json_post("/tfd/cases/#{tfd.id}/cancel", { reason: text })
  def errors = json_body["problems"].map { |p| p["error"] }
  def payloads(name) = DomainEvent.where(name: name).map(&:payload)

  before { stepped_up!(committee) }

  it "autorizar sem atendimento marcado nem unidade de faturamento → appointment_required e billing_unit_missing juntos" do
    tfd = tfd_case!(status: "submitted")
    decide(tfd, "authorize")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(errors).to contain_exactly("appointment_required", "billing_unit_missing")
    expect(tfd.reload.status).to eq("submitted")
    expect(payloads("tfd.case_decided")).to be_empty
  end

  it "autorizar repete as regras do envio, todas de uma vez" do
    tfd = tfd_case!(status: "submitted", report: { "cid10" => nil, "justification" => "curta" })
    decide(tfd, "authorize")
    expect(errors).to contain_exactly("appointment_required", "billing_unit_missing", "cid_required", "justification_required")
  end

  it "marca o atendimento e autoriza: evento authorized com o motivo cifrado; tfd.case_decided só com ids e a decisão" do
    TransportSetting.current.update!(tfd_billing_health_unit: health_management_unit!)
    provider = external_provider!(name: "Hospital do Rim")
    tfd = tfd_case!(status: "submitted")
    set_appointment(tfd, provider_id: provider.id)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "submitted", "provider" => { "id" => provider.id, "name" => "Hospital do Rim" })
    expect(Time.iso8601(json_body["appointment_at"])).to eq(Time.iso8601(appointment_at))
    expect(json_body["events"].last).to include("kind" => "appointment_set", "reason" => nil)
    expect(payloads("tfd.case_updated")).to contain_exactly({ "tfd_case_id" => tfd.id, "user_id" => committee.id })

    decide(tfd, "authorize")
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to include("id", "patient", "report", "legs", "events", "trip_passengers")
    expect(json_body["status"]).to eq("authorized")
    expect(json_body["events"].last).to include("kind" => "authorized", "reason" => reason)
    event = tfd.tfd_case_events.reload.find_by!(kind: "authorized")
    expect(event.by_user_id).to eq(committee.id)
    expect(event.reason_before_type_cast).not_to include("pactuado")
    expect(payloads("tfd.case_decided")).to contain_exactly({ "tfd_case_id" => tfd.id, "user_id" => committee.id, "decision" => "authorize" })
    expect(DomainEvent.where(name: %w[tfd.case_decided tfd.case_updated]).map(&:payload).to_s).not_to include("pactuado", "N185", "Rim")
  end

  it "devolver → returned; o autor edita e reenvia → submitted" do
    tfd = tfd_case!(status: "submitted")
    decide(tfd, "return", "Falta descrever a indisponibilidade no município")
    expect(response).to have_http_status(:ok)
    expect(json_body["status"]).to eq("returned")
    expect(payloads("tfd.case_decided")).to contain_exactly(include("decision" => "return"))

    sign_in_as(tfd.requester_user)
    json_patch "/tfd/cases/#{tfd.id}", { patient_id: tfd.patient_id, consultation_id: tfd.consultation_id,
                                         destination_id: tfd.transport_destination_id,
                                         report: TransportHelpers::TFD_REPORT.merge("justification" => "Sem nefrologia e sem hemodiálise no município") }
    expect(response).to have_http_status(:ok)
    json_post "/tfd/cases/#{tfd.id}/submit"
    expect(response).to have_http_status(:ok)
    expect(json_body["status"]).to eq("submitted")
    expect(json_body["events"].map { |e| e["kind"] }).to eq(%w[created submitted returned submitted])
  end

  it "recusar → denied, e depois nada mais é aceito (invalid_transition)" do
    tfd = tfd_case!(status: "submitted")
    decide(tfd, "deny", "Procedimento disponível na rede do município")
    expect(json_body["status"]).to eq("denied")
    decide(tfd, "authorize")
    expect(json_body).to include("error" => "invalid_transition")
    set_appointment(tfd)
    expect(json_body).to include("error" => "invalid_transition")
    cancel(tfd)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_transition")
    expect(tfd.reload).to have_attributes(status: "denied", appointment_at: nil)
    expect(tfd.tfd_case_events.pluck(:kind)).to eq(%w[created submitted denied])
  end

  it "decisão e motivo inválidos vêm juntos; motivo fora de 10..500 recusado" do
    tfd = tfd_case!(status: "submitted")
    decide(tfd, "approve", "curto")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["problems"]).to contain_exactly({ "path" => "decision", "error" => "invalid_request" },
                                                     { "path" => "reason", "error" => "invalid_request" })
    decide(tfd, "deny", "x" * 501)
    expect(json_body).to include("error" => "invalid_request", "path" => "reason")
    json_post "/tfd/cases/#{tfd.id}/decide", { decision: "deny", reason: reason, extra: 1 }
    expect(json_body).to include("error" => "invalid_request", "path" => "extra")
    expect(tfd.reload.status).to eq("submitted")
  end

  it "sem step-up → 401 mfa_required em toda escrita da comissão" do
    tfd = tfd_case!(status: "scheduled")
    sign_in_as(committee)
    decide(tfd, "deny")
    expect(response).to have_http_status(:unauthorized)
    expect(json_body).to eq("error" => "mfa_required")
    [ -> { set_appointment(tfd) }, -> { inpatient(tfd, from: Date.current.iso8601) }, -> { cancel(tfd) } ].each do |write|
      write.call
      expect(response).to have_http_status(:unauthorized)
    end
    expect(tfd.reload.status).to eq("scheduled")
  end

  it "médico autor, mesmo com step-up, não decide nem cancela → 403 missing_role" do
    tfd = tfd_case!(status: "submitted")
    stepped_up!(tfd.requester_user)
    decide(tfd, "authorize")
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")
    cancel(tfd)
    expect(response).to have_http_status(:forbidden)
    expect(tfd.reload.status).to eq("submitted")
  end

  it "atendimento: data fora de agora − 1 dia..+365 dias, sem fuso ou prestador próprio → invalid_request; só submitted/authorized/scheduled" do
    tfd = tfd_case!(status: "submitted")
    set_appointment(tfd, appointment_at: (Time.zone.now - 2.days).iso8601, provider_id: own_provider!(create_unit("UBS Própria")).id)
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("appointment_at", "provider_id")
    set_appointment(tfd, appointment_at: (Time.zone.now + 366.days).iso8601)
    expect(json_body).to include("error" => "invalid_request", "path" => "appointment_at")
    set_appointment(tfd, appointment_at: "2026-12-01T09:00")
    expect(json_body).to include("path" => "appointment_at")
    expect(tfd.reload.appointment_at).to be_nil
    returned = tfd_case!(status: "returned")
    set_appointment(returned)
    expect(json_body).to include("error" => "invalid_transition")
    scheduled = tfd_case!(status: "scheduled")
    set_appointment(scheduled)
    expect(response).to have_http_status(:ok)
    expect(json_body["status"]).to eq("scheduled")
  end

  # Internação de 20 dias atrás em diante (D2: até hoje e não antes do envio − 1 dia).
  def d(offset) = (Date.current - 20 + offset).iso8601
  def submitted_long_ago!(tfd) = tfd.tap { |row| row.update_columns(submitted_at: 30.days.ago) }

  it "internação aberta e fechada aparece em inpatient; outra aberta com outro from → inpatient_open; cruzamento → inpatient_overlap" do
    tfd = submitted_long_ago!(tfd_case!(status: "scheduled"))
    inpatient(tfd, from: d(0))
    expect(response).to have_http_status(:ok)
    expect(json_body["inpatient"]).to eq([ { "from" => d(0), "to" => nil } ])
    expect(json_body["status"]).to eq("scheduled")
    inpatient(tfd, from: d(2))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "inpatient_open", "path" => "from")
    inpatient(tfd, from: d(0), to: d(4))
    expect(json_body["inpatient"]).to eq([ { "from" => d(0), "to" => d(4) } ])
    inpatient(tfd, from: d(3), to: d(6))
    expect(json_body).to include("error" => "inpatient_overlap")
    inpatient(tfd, from: d(10), to: d(8))
    expect(json_body).to include("error" => "invalid_request", "path" => "to")
    inpatient(tfd, from: d(4), to: d(5))
    expect(json_body["inpatient"]).to eq([ { "from" => d(0), "to" => d(4) }, { "from" => d(4), "to" => d(5) } ])
    expect(tfd.reload.inpatient_stays).to eq([ { "from" => d(0), "to" => d(4) }, { "from" => d(4), "to" => d(5) } ])
    expect(tfd.tfd_case_events.where(kind: "inpatient_recorded").count).to eq(3)
    expect(payloads("tfd.case_updated").size).to eq(3)
  end

  it "internação: só scheduled/travelling; aberta antes de uma fechada que termina depois → inpatient_overlap" do
    authorized = tfd_case!(status: "authorized")
    inpatient(authorized, from: d(0))
    expect(json_body).to include("error" => "invalid_transition")
    tfd = submitted_long_ago!(tfd_case!(status: "travelling"))
    inpatient(tfd, from: d(0), to: d(2))
    inpatient(tfd, from: d(1))
    expect(json_body).to include("error" => "inpatient_overlap")
    inpatient(tfd, from: "2026-11-31")
    expect(json_body).to include("error" => "invalid_request", "path" => "from")
    expect(tfd.reload.inpatient_stays).to eq([ { "from" => d(0), "to" => d(2) } ])
    inpatient(tfd, from: d(10))
    expect { inpatient(tfd, from: d(10)) }.not_to(change { tfd.tfd_case_events.reload.count })
    expect(response).to have_http_status(:ok)
    expect(json_body["inpatient"]).to eq([ { "from" => d(0), "to" => d(2) }, { "from" => d(10), "to" => nil } ])
  end

  it "D2: internação entre (ida mais antiga ou envio) − 1 dia e hoje; alta até hoje; fora → invalid_request no campo" do
    tfd = submitted_long_ago!(tfd_case!(status: "scheduled"))
    floor = Date.current - 31 # envio há 30 dias − 1
    inpatient(tfd, from: (floor - 1).iso8601)
    expect(json_body).to include("error" => "invalid_request", "path" => "from")
    inpatient(tfd, from: (Date.current + 1).iso8601)
    expect(json_body).to include("error" => "invalid_request", "path" => "from")
    inpatient(tfd, from: (Date.current - 2).iso8601, to: (Date.current + 1).iso8601)
    expect(json_body).to include("error" => "invalid_request", "path" => "to")
    expect(tfd.reload.inpatient_stays).to be_blank

    # Com ida registrada, o piso é a data dela − 1.
    Tfd::AddLeg.call(tfd_case: tfd, by: committee, attrs: { "direction" => "outbound", "mode" => "bus_ticket",
                                                           "date" => (Date.current - 5).iso8601,
                                                           "ticket" => { "amount_cents" => 100, "carrier" => "Viação" } })
    inpatient(tfd, from: (Date.current - 7).iso8601)
    expect(json_body).to include("error" => "invalid_request", "path" => "from")
    inpatient(tfd, from: (Date.current - 6).iso8601, to: Date.current.iso8601)
    expect(response).to have_http_status(:ok)
    expect(json_body["inpatient"]).to eq([ { "from" => (Date.current - 6).iso8601, "to" => Date.current.iso8601 } ])
  end

  it "rascunho é invisível à comissão: as quatro escritas dão 404 e nada muda" do
    draft = tfd_case!(status: "draft")
    [ -> { decide(draft, "deny") }, -> { set_appointment(draft) }, -> { inpatient(draft, from: "2026-11-10") },
      -> { cancel(draft) } ].each do |write|
      write.call
      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "not_found")
    end
    expect(draft.reload).to have_attributes(status: "draft", appointment_at: nil, inpatient_stays: [])
    expect(draft.tfd_case_events.pluck(:kind)).to eq(%w[created])
  end

  it "cancelar: agendado → cancelled com evento; tfd.case_cancelled só com ids; motivo curto e terminal recusados" do
    tfd = tfd_case!(status: "scheduled")
    cancel(tfd, "curto")
    expect(json_body).to include("error" => "invalid_request", "path" => "reason")
    cancel(tfd, "Paciente transferido para outro município")
    expect(response).to have_http_status(:ok)
    expect(json_body["status"]).to eq("cancelled")
    expect(json_body["events"].last).to include("kind" => "cancelled", "reason" => "Paciente transferido para outro município")
    expect(payloads("tfd.case_cancelled")).to contain_exactly({ "tfd_case_id" => tfd.id, "user_id" => committee.id })
    cancel(tfd)
    expect(json_body).to include("error" => "invalid_transition")
  end

  it "cancela de submitted, returned, authorized e travelling" do
    %w[submitted returned authorized travelling].each do |status|
      tfd = tfd_case!(status: status)
      cancel(tfd)
      expect(response).to have_http_status(:ok), "#{status}: #{response.body}"
      expect(tfd.reload.status).to eq("cancelled")
      expect(tfd.tfd_case_events.last.kind).to eq("cancelled")
    end
  end

  it "autorizar com o atendimento já no passado (devolvido e reenviado com a data velha) → appointment_required" do
    TransportSetting.current.update!(tfd_billing_health_unit: health_management_unit!)
    tfd = tfd_case!(status: "submitted")
    set_appointment(tfd)
    tfd.update_columns(appointment_at: 2.hours.ago)
    decide(tfd, "authorize")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "appointment_required", "path" => "appointment_at")
    expect(tfd.reload.status).to eq("submitted")
  end

  it "autorizar repete distância mínima e destino metropolitano" do
    near = destination!(name: "Araucária", ibge: "4101804", km: 27, metropolitan: true)
    tfd = tfd_case!(status: "submitted", destination: near)
    decide(tfd, "authorize")
    expect(errors).to include("distance_below_minimum", "metropolitan_destination")
  end

  it "atendimento sem provider_id mantém o prestador; horário em Z guarda o instante" do
    provider = external_provider!(name: "Hospital do Rim")
    tfd = tfd_case!(status: "authorized")
    set_appointment(tfd, provider_id: provider.id)
    instant = (Time.now.utc + 10.days).change(hour: 13, min: 30, sec: 0)
    set_appointment(tfd, appointment_at: instant.strftime("%Y-%m-%dT%H:%M:%SZ"))
    expect(response).to have_http_status(:ok)
    expect(json_body["provider"]).to eq("id" => provider.id, "name" => "Hospital do Rim")
    expect(tfd.reload.care_provider_id).to eq(provider.id)
    expect(tfd.appointment_at).to eq(instant)
    expect(Time.iso8601(json_body["appointment_at"])).to eq(instant)
  end

  it "atendimento: provider_id inexistente, inativo ou não UUID → invalid_request provider_id" do
    tfd = tfd_case!(status: "submitted")
    inactive = external_provider!(name: "Hospital Fechado")
    inactive.update!(active: false)
    [ SecureRandom.uuid, inactive.id, "123", 42 ].each do |id|
      set_appointment(tfd, provider_id: id)
      expect(json_body).to include("error" => "invalid_request", "path" => "provider_id")
    end
    expect(tfd.reload).to have_attributes(appointment_at: nil, care_provider_id: nil)
  end

  it "médico autor, com step-up, não marca atendimento nem registra internação → 403" do
    tfd = tfd_case!(status: "scheduled")
    stepped_up!(tfd.requester_user)
    set_appointment(tfd)
    expect(response).to have_http_status(:forbidden)
    inpatient(tfd, from: "2026-11-10")
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")
    expect(tfd.reload).to have_attributes(appointment_at: nil, inpatient_stays: [])
  end

  it "processo inexistente → 404" do
    decide(Struct.new(:id).new(SecureRandom.uuid), "deny")
    expect(response).to have_http_status(:not_found)
  end
end

RSpec.describe "TFD — comissão sem faturamento", type: :request do
  let!(:city) { transport_city!(tfd: true) }

  it "com procedure_billing desligado autoriza sem unidade de faturamento (T12)" do
    committee = committee!
    stepped_up!(committee)
    expect(Billing::Gate.enabled?(city)).to be(false)
    tfd = tfd_case!(status: "submitted")
    json_post "/tfd/cases/#{tfd.id}/appointment", { appointment_at: (Time.zone.now + 3.days).iso8601 }
    json_post "/tfd/cases/#{tfd.id}/decide", { decision: "authorize", reason: "Laudo completo e destino pactuado" }
    expect(response).to have_http_status(:ok)
    expect(json_body["status"]).to eq("authorized")
  end
end
