require "rails_helper"

# Módulo 32b (ADR 0050; contrato §4 e §12 Q3; plano, Desvios 1 e 2; Review
# Focus 4): as horas da observação contam desde a PRIMEIRA entrada do
# encontro (a troca de leito e a saída seguida de nova entrada não zeram), o
# alerta de 20 h e 24 h, o mapa (leitos e `waiting_bed`, A1) e os campos da fila.
RSpec.describe Urgency::Observation do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:doctor) { observation_doctor!(upa) }
  after { Current.reset }

  describe ".hours e .alert" do
    let(:start) { Time.zone.parse("2026-11-10 08:00") }

    it "conta horas inteiras: 19 h 59 → 19 e sem alerta; 20 h → near_limit; 24 h → over_limit" do
      expect(described_class.hours(start, start + 19.hours + 59.minutes)).to eq(19)
      expect(described_class.alert(19)).to be_nil
      expect(described_class.hours(start, start + 20.hours)).to eq(20)
      expect(described_class.alert(20)).to eq("near_limit")
      expect(described_class.alert(23)).to eq("near_limit")
      expect(described_class.hours(start, start + 24.hours)).to eq(24)
      expect(described_class.alert(24)).to eq("over_limit")
      expect(described_class.alert(40)).to eq("over_limit")
      expect(described_class.hours(start, start)).to eq(0)
    end
  end

  it "a troca de leito às 23 h mantém a conta desde a 1ª entrada, e o leito antigo fica livre no mesmo instante (Review Focus 4)" do
    first_bed = urgency_bed!(upa, label: "OBS 01")
    second_bed = urgency_bed!(upa, label: "OBS 02")
    encounter, other = travel_to(23.hours.ago) do
      [ in_care_encounter!(upa), in_care_encounter!(upa) ].tap { |e, _| observed!(e, bed: first_bed) }
    end

    now = Time.current
    observed!(encounter, bed: second_bed, now: now)
    # O leito antigo livre no MESMO instante: [started_at, ended_at) não sobrepõe.
    observed!(other, bed: first_bed, now: now)

    board = described_class.board(upa, now: now)
    stays = board[:beds].to_h { |b| [ b[:label], b[:stay] ] }
    expect(stays["OBS 02"]).to include(encounter_id: encounter.id, hours: 23, alert: "near_limit", started_at: now.iso8601)
    expect(stays["OBS 01"]).to include(encounter_id: other.id, hours: 0, alert: nil)
    expect(described_class.queue_fields([ encounter.id ], now: now + 1.hour))
      .to eq(encounter.id => { bed_label: "OBS 02", hours: 24, alert: "over_limit" })

    # Sair e voltar não zera: a pausa conta.
    expect(Urgency::EndObservation.call(encounter: encounter, by: doctor, now: now + 2.hours)).to be_ok
    observed!(encounter, bed: second_bed, now: now + 3.hours)
    expect(described_class.queue_fields([ encounter.id ], now: now + 3.hours).dig(encounter.id, :hours)).to eq(26)
    expect(UrgencyBedStay.where(urgency_encounter_id: encounter.id).order(:started_at).pluck(:end_kind))
      .to eq([ "bed_change", "observation_ended", nil ])
  end

  describe ".board" do
    it "leitos por rótulo (o inativo livre fica fora), a estadia sem texto clínico e waiting_bed = em atendimento sem leito, por chamada" do
      bed_b = urgency_bed!(upa, label: "OBS 02")
      bed_a = urgency_bed!(upa, label: "OBS 01")
      urgency_bed!(upa, label: "OBS 03", active: false)
      urgency_bed!(upa!, label: "OUTRA")
      early = travel_to(30.minutes.ago) { in_care_encounter!(upa) }
      late = travel_to(10.minutes.ago) { in_care_encounter!(upa) }
      placed = in_care_encounter!(upa)
      classified = arrived!(upa).tap { |e| classified!(e, color: "yellow", by: observation_nurse!(upa)) }
      stay = observed!(placed, bed: bed_b)

      board = described_class.board(upa)
      expect(board[:beds].map { |b| b[:label] }).to eq([ "OBS 01", "OBS 02" ])
      expect(board[:beds].first).to eq(bed_id: bed_a.id, label: "OBS 01", active: true, stay: nil)
      expect(board[:beds].last).to eq(
        bed_id: bed_b.id, label: "OBS 02", active: true,
        stay: { stay_id: stay.id, encounter_id: placed.id, ticket: placed.attendance.ticket,
                patient: Urgency::PatientRef.call(placed.patient), started_at: stay.started_at.iso8601, hours: 0, alert: nil }
      )
      expect(board[:waiting_bed].map { |w| w[:encounter_id] }).to eq([ early.id, late.id ])
      expect(board[:waiting_bed].first).to eq(encounter_id: early.id, ticket: early.attendance.ticket,
                                              patient: Urgency::PatientRef.call(early.patient),
                                              called_at: early.attendance.reload.called_at.iso8601)
      expect(board.to_s).not_to include(classified.id)
      expect(board.to_s).not_to include(UrgencyHelpers::COMPLAINT)
    end

    it "um leito inativo com estadia aberta (defensivo) continua no mapa" do
      bed = urgency_bed!(upa, label: "OBS 09")
      observed!(in_care_encounter!(upa), bed: bed)
      bed.update_columns(active: false)
      expect(described_class.board(upa)[:beds].sole).to include(bed_id: bed.id, active: false, stay: be_present)
    end
  end

  it ".queue_fields: só quem tem estadia aberta, num punhado de consultas" do
    bed = urgency_bed!(upa, label: "OBS 05")
    placed = in_care_encounter!(upa)
    free = in_care_encounter!(upa)
    observed!(placed, bed: bed)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    fields = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      described_class.queue_fields([ placed.id, free.id ], now: Time.current)
    end
    expect(fields).to eq(placed.id => { bed_label: "OBS 05", hours: 0, alert: nil })
    expect(queries).to be <= 3
    expect(described_class.queue_fields([], now: Time.current)).to eq({})
  end
end
