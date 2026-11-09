require "rails_helper"

# Módulo 32a (ADR 0050; contrato §6 e §14 Q6, Q18; plano, Desvios 9 e 11;
# Review Focus 3): a fila da UPA em três grupos, a ordem por cor e chegada (a
# mesma no SQL da tela e do "chamar próximo"), o estouro pelo relógio da 1ª
# classificação contra o tempo da vigente, e nenhum texto clínico.
RSpec.describe Urgency::Queue do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  before { urgency_protocol! }
  after { Current.reset }

  def classified_at(minutes_ago, color, n)
    travel_to(minutes_ago.minutes.ago) do
      arrived!(upa, patient: urgency_patient!(n)).tap { |e| classified!(e, color: color, by: nurse, justification: "Conferido na classificação") }
    end
  end

  it "ordena por cor e chegada; reclassificar para cima sobe e marca o estouro pelo relógio da 1ª classificação" do
    yellow = classified_at(55, "yellow", 1)
    green = classified_at(50, "green", 2)
    red = classified_at(5, "red", 3)
    waiting = arrived!(upa, patient: urgency_patient!(4))
    groups = described_class.groups(upa)
    expect(groups[:by_color].map { |i| i[:encounter_id] }).to eq([ red.id, yellow.id, green.id ])
    expect(groups[:awaiting_classification].map { |i| i[:encounter_id] }).to eq([ waiting.id ])
    classified!(green, color: "orange", by: nurse, justification: "Piora da dor torácica")
    items = described_class.groups(upa)[:by_color]
    expect(items.map { |i| i[:encounter_id] }).to eq([ red.id, green.id, yellow.id ])
    expect(items.find { |i| i[:encounter_id] == green.id }).to include(color: "orange", overdue: true, max_wait_minutes: 10)
    expect(items.find { |i| i[:encounter_id] == yellow.id }[:overdue]).to be(false)
    called = ApplicationRecord.transaction { described_class.lock_next_classified(upa.id) }
    expect(called.id).to eq(red.attendance_id)

    # "Chamar próximo": o vermelho, depois o reclassificado laranja, antes do
    # amarelo que chegou antes dele; quem não foi classificado nunca.
    ids = Array.new(3) { Attendances::CallNext.call(health_unit_id: upa.id, by: doctor, urgency: true).payload[:attendance]&.id }
    expect(ids).to eq([ red.attendance_id, green.attendance_id, yellow.attendance_id ])
    expect(Attendances::CallNext.call(health_unit_id: upa.id, by: doctor, urgency: true).reason).to eq(:queue_empty)
    expect(waiting.attendance.reload.status).to eq("waiting")
  end

  it "o relógio do estouro é a 1ª classificação, não a chegada; na mesma cor, vale a chegada" do
    # Chegou há 30 min e foi classificado laranja há 8: 8 ≤ 10, não estoura
    # (pela chegada estouraria). Os dois amarelos: o que chegou antes vem
    # primeiro, mesmo classificado depois.
    late = travel_to(30.minutes.ago) { arrived!(upa, patient: urgency_patient!(11)) }
    travel_to(8.minutes.ago) { classified!(late, color: "orange", by: nurse) }
    early_yellow = travel_to(40.minutes.ago) { arrived!(upa, patient: urgency_patient!(12)) }
    later_yellow = travel_to(20.minutes.ago) { arrived!(upa, patient: urgency_patient!(13)) }
    travel_to(15.minutes.ago) { classified!(later_yellow, color: "yellow", by: nurse) }
    travel_to(5.minutes.ago) { classified!(early_yellow, color: "yellow", by: nurse) }
    items = described_class.groups(upa)[:by_color]
    expect(items.map { |i| i[:encounter_id] }).to eq([ late.id, early_yellow.id, later_yellow.id ])
    expect(items.first).to include(overdue: false, waited_minutes: 30, max_wait_minutes: 10)
    expect(items.first[:classified_at]).to eq(late.reload.first_classified_at.iso8601)
    travel_to(3.minutes.from_now) { expect(described_class.groups(upa)[:by_color].first[:overdue]).to be(true) }
    called = ApplicationRecord.transaction { described_class.lock_next_classified(upa.id) }
    expect(called.id).to eq(late.attendance_id)
  end

  it "o item traz a senha, a pessoa, a espera e a última chamada; em atendimento nunca estoura e a reclassificação não tira de lá" do
    green = classified_at(50, "green", 6)
    waiting = travel_to(12.minutes.ago) { arrived!(upa, patient: urgency_patient!(7)) }
    item = described_class.groups(upa)[:awaiting_classification].first
    expect(item).to include(encounter_id: waiting.id, attendance_id: waiting.attendance_id, ticket: waiting.attendance.ticket,
                            waited_minutes: 12, last_call: nil, max_wait_minutes: nil)
    expect(item[:patient]).to include(patient_id: waiting.patient.id, unidentified: false)
    expect(item[:patient]).not_to have_key(:description)
    expect(item[:arrived_at]).to eq(waiting.attendance.checked_in_at.iso8601)

    called!(green, by: doctor)
    classified!(green, color: "orange", by: nurse, justification: "Piora da dor torácica")
    expect(green.reload.state).to eq("in_care")
    expect(green.overdue?).to be(false)
    groups = described_class.groups(upa)
    expect(groups[:by_color]).to be_empty
    in_care = groups[:in_care].sole
    expect(in_care).to include(encounter_id: green.id, attendance_id: green.attendance_id, color: "orange", max_wait_minutes: 10,
                               consultation_id: nil, consultation_status: nil, waited_minutes: 50)
    expect(in_care[:called_at]).to eq(green.attendance.reload.called_at.iso8601)
    expect(in_care[:called_by_name]).to be_present
    expect(in_care).not_to have_key(:overdue)
  end

  context "com a sala de espera" do
    let!(:city) { urgency_city!(waiting_room: true) }

    it "last_call é a chamada mais recente: tipo, local e hora" do
      room = call_location!(upa, name: "Classificação")
      office = call_location!(upa, name: "Consultório 2")
      encounter = arrived!(upa, patient: urgency_patient!(8))
      travel_to(2.minutes.ago) { Urgency::CallForClassification.call(encounter: encounter, call_location_id: nil, by: nurse, waiting_room: true) }
      Urgency::CallForClassification.call(encounter: encounter, call_location_id: room.id, by: nurse, waiting_room: true)
      last = described_class.groups(upa)[:awaiting_classification].first[:last_call]
      expect(last).to eq(kind: "classification", location: "Classificação", called_at: AttendanceCall.order(:called_at).last.called_at.iso8601)
      classified!(encounter, color: "green", by: nurse)
      called!(encounter, by: doctor, call_location: office)
      expect(described_class.groups(upa)[:in_care].first[:last_call]).to include(kind: "care", location: "Consultório 2")
    end
  end

  it "nenhum item traz texto clínico" do
    e = classified_at(1, "green", 5)
    text = described_class.groups(upa).to_s
    expect(text).not_to include(e.current_classification.complaint)
    expect(text).not_to include(e.current_classification.justification)
  end
end
