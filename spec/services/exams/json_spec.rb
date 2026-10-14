require "rails_helper"

# Divergência D5: a forma administrativa nunca leva valores, crítico, PDF,
# CID nem CNS do solicitante.
RSpec.describe Exams::Json do
  before { exam_city! }

  it "clínica × administrativa" do
    unit = create_unit("UBS Json")
    doctor = doctor!(unit)
    order = exam_order!(patient: exam_patient!(30).first, unit: unit, requester: doctor)
    file = pdf_file!(user: doctor).tap { |f| f.update!(consumed_at: Time.current) }
    ExamResult.create!(exam_order: order, patient: order.patient, sigtap_code: order.sigtap_code, origin: "order", source: "unit",
                       pdf_file: file, values: [ { "key" => "hba1c", "label" => "HbA1c", "value" => "9.1", "unit" => "%", "loinc" => "4548-4" } ].to_json,
                       released_on: Time.zone.today, laboratory_name: "Lab", critical: true, registered_by_user: doctor)
    clinical = described_class.order(order.reload, view: :clinical, user: doctor)
    admin = described_class.order(order, view: :administrative, user: doctor)
    expect(clinical[:result]).to include(critical: true, values: [ hash_including("value" => "9.1") ])
    expect(clinical[:result][:pdf_url]).to start_with("/exams/files/")
    expect(admin[:result].keys).to eq(%i[id origin source released_on laboratory_name])
    # result_fields (campos do catálogo, sem valor do paciente) vão nas duas
    # visões: a unidade registra o resultado pelo formulário (dashboard D6).
    expect(admin.to_json).not_to include("9.1")
    expect(admin.except(:result_fields).to_json).not_to include("4548-4")
    expect(admin[:result_fields]).to eq(clinical[:result_fields])
    expect(admin[:requester][:cns]).to be_nil
    expect(described_class.order(order, view: :clinical, user: doctor, events: false)).not_to have_key(:events)
    expect(clinical[:label]).to eq("DOSAGEM DE HEMOGLOBINA GLICOSILADA")
    expect(clinical[:consultation_id]).to be_nil
    expect(clinical[:result_fields]).to eq([ { "key" => "hba1c", "label" => "Hemoglobina glicada", "unit" => "%", "loinc" => "4548-4" } ])
  end

  # A45: o id do pedido da consulta, nas duas visões (null fora da consulta).
  it "consultation_exam_request_id: o id do pedido da consulta, nas duas visões; null na guia" do
    unit = create_unit("UBS Json A45")
    doctor = doctor!(unit)
    guide = exam_order!(patient: exam_patient!(32).first, unit: unit, requester: doctor)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(41))
    request = consultation.exam_requests.first
    linked = ExamOrder.find_by!(consultation_exam_request_id: request.id)
    %i[clinical administrative].each do |view|
      expect(described_class.order(linked, view: view, user: doctor)[:consultation_exam_request_id]).to eq(request.id)
      expect(described_class.order(guide, view: view, user: doctor)).to include(consultation_exam_request_id: nil)
    end
  end

  # A16/A28: o evento do job diário vem com ator system (name null);
  # instantes ISO 8601 sem fração de segundo ($defs/instant do contrato).
  it "ator system, motivo por visão e instantes sem fração" do
    unit = create_unit("UBS Json Eventos")
    doctor = doctor!(unit)
    order = exam_order!(patient: exam_patient!(31).first, unit: unit, requester: doctor)
    ApplicationRecord.transaction do
      order.lock!
      Exams::Escalate.call(order: order, reason: "overdue", now: Time.zone.local(2026, 10, 13, 10, 0, 0.5r))
    end
    ApplicationRecord.transaction do
      order.lock!
      Exams::Transition.call(order: order, kind: "cancelled", actor_user: doctor, reason: "Paciente fez em outro serviço")
    end
    clinical = described_class.order(order.reload, view: :clinical, user: doctor)
    admin = described_class.order(order, view: :administrative, user: doctor)
    escalated = clinical[:events].find { |e| e[:kind] == "escalated" }
    expect(escalated).to eq(kind: "escalated", occurred_at: "2026-10-13T10:00:00-03:00", actor: { type: "system", name: nil },
                            reason: "overdue")
    expect(clinical[:events].find { |e| e[:kind] == "requested" }[:actor]).to eq(type: "user", name: Screenings::Json.staff_name(doctor))
    expect(clinical[:events].find { |e| e[:kind] == "cancelled" }[:reason]).to eq("Paciente fez em outro serviço")
    # A32: negar e cancelar mostram o motivo nas duas visões; o escalonamento
    # e a ciência pela equipe, só na clínica.
    expect(admin[:events].find { |e| e[:kind] == "cancelled" }[:reason]).to eq("Paciente fez em outro serviço")
    expect(admin[:events].find { |e| e[:kind] == "escalated" }[:reason]).to be_nil
    denied = ExamOrderEvent.new(kind: "denied", reason: "Fora do protocolo", occurred_at: Time.current)
    team_ack = ExamOrderEvent.new(kind: "acknowledged", reason: "Solicitante de férias", occurred_at: Time.current)
    expect(%i[clinical administrative].map { |view| described_class.event(denied, view: view)[:reason] })
      .to eq([ "Fora do protocolo", "Fora do protocolo" ])
    expect(%i[clinical administrative].map { |view| described_class.event(team_ack, view: view)[:reason] })
      .to eq([ "Solicitante de férias", nil ])
    instant = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})\z/
    expect([ clinical[:status_changed_at], *clinical[:events].map { |e| e[:occurred_at] } ]).to all(match(instant))
  end

  it "evento do prestador e forma do portal" do
    unit = create_unit("UBS Json Portal")
    doctor = doctor!(unit)
    patient, = exam_patient!(32)
    order = exam_order!(patient: patient, unit: unit, requester: doctor)
    provider = exam_provider!
    ApplicationRecord.transaction do
      order.lock!
      Exams::Transition.call(order: order, kind: "scheduled", actor_provider: provider,
                             changes: { exam_provider_id: provider.id, scheduled_at: Time.zone.local(2026, 11, 3, 8, 30, 0.25r),
                                        scheduled_place: "Rua A, 10" })
    end
    expect(described_class.event(order.reload.events.last, view: :administrative)[:actor]).to eq(type: "provider", name: provider.name)
    portal = described_class.provider_order(order)
    expect(portal.keys).to eq(%i[id short_code patient sigtap_code label priority status scheduled_at scheduled_place overdue result_fields])
    expect(portal[:patient]).to eq(name: patient.display_name, birth_date: patient.birth_date, cpf_last3: patient.cpf[-3, 3])
    expect(portal[:scheduled_at]).to eq("2026-11-03T08:30:00-03:00")
  end
end
