require "rails_helper"

# ADR 0040 (spec §5): fontes existentes, sem cópia; plano, Desvio 9.
RSpec.describe CareLines::Sources do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:nurse) { care_nurse!(unit) }
  let(:all) { %w[consultation blood_pressure weight_height exam:0202010503 procedure:0301040095] }

  it "consulta (CBO e códigos), PA e peso+altura da consulta e da escuta, exame pedido/resultado e procedimento" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    citizen = Citizen.find_by!(patient_id: patient.id)
    care_screening!(unit: unit, citizen: citizen, by: nurse, vitals: { "systolic" => 150, "diastolic" => 95 })
    exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: "0202010503", status: :awaiting_authorization)
    cancelled = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: "0202010503", status: :awaiting_authorization)
    ExamOrder.transaction do # a ordem nasce aguardando (trigger); cancelar exige evento da mesma transação
      ExamOrderEvent.create!(exam_order: cancelled, kind: "cancelled", actor_user: doctor, occurred_at: Time.current, reason: "duplicado")
      cancelled.update!(status: "cancelled", status_changed_at: Time.current)
    end
    raw_procedure!(unit: unit, patient: patient, professional: doctor, sigtap_code: "0301040095", cid10: nil)
    today = Time.zone.today

    events = described_class.load(patient_ids: [ patient.id ], sources: all, since: today - 365).fetch(patient.id)
    expect(events["consultation"].map { |e| [ e.on, e.cbo, e.codes ] }).to eq([ [ today, "225125", [ %w[ciap2 T90] ] ] ])
    expect(events["blood_pressure"].map(&:on)).to eq([ today, today ]) # consulta (130/85) e escuta (150/95)
    expect(events["weight_height"].map(&:on)).to eq([ today ])         # só a consulta tem peso e altura
    expect(events["exam:0202010503"].map(&:on)).to eq([ today ])        # o cancelado não conta
    expect(events["procedure:0301040095"].map(&:on)).to eq([ today ])
    expect(cancelled.status).to eq("cancelled")
  end

  it "fora da janela (since) não vem; paciente sem nada vem vazio" do
    patient = care_patient!(age: 40, sex: "female")
    expect(described_class.load(patient_ids: [ patient.id ], sources: all, since: Time.zone.today)).to eq(patient.id => {})
  end

  it "uma consulta por fonte: o número de SQL não cresce com o número de pacientes" do
    patients = Array.new(5) { care_patient!(age: 50, sex: "female", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor) }
    count = lambda do |ids|
      queries = 0
      callback = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:sql].start_with?("SAVEPOINT", "RELEASE") }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        described_class.load(patient_ids: ids, sources: all, since: Time.zone.today - 365)
      end
      queries
    end
    expect(count.call(patients.first(1).map(&:id))).to eq(count.call(patients.map(&:id)))
    expect(count.call(patients.map(&:id))).to be <= 6
  end
end
