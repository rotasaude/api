require "rails_helper"

# Módulo 29, Task 9 (ADR 0047, Desvios 9, 10, 12 e 13; contrato §5; §15 V14,
# V19): transcrição da caderneta de papel.
RSpec.describe Vaccination::RecordTranscription do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room, role: "vaccinator") }
  let(:child) { vaccine_patient!(birth_date: Date.current - 61, sex: "female") }

  def item(**over) = { "immunobiological_code" => "15", "dose_code" => "9", "applied_on" => (Date.current - 55).iso8601 }.merge(over.transform_keys(&:to_s))
  def call(items, close_check: false, patient: child, by: vaccinator, now: Time.current)
    described_class.call(room: room, patient: patient, items: items, close_check: close_check, by: by, now: now)
  end

  it "transcrição com close_check grava a conferência transcribed e libera o atraso" do
    result = call([ item("place" => "Maternidade") ], close_check: true)
    expect(VaccinationRecordCheck.sole).to have_attributes(mode: "transcribed", vaccine_room_id: room.id, checked_by_user_id: vaccinator.id)
    expect(result.payload[:immunizations].sole).to have_attributes(transcription: true, stock_lot_id: nil)
    expect(result.payload[:card][:checked]).to include(mode: "transcribed")
    expect(VaccinationStatus.where(patient_id: child.id).pluck(:checked).uniq).to eq([ true ])
  end

  it "grava a dose: 12:00 na cidade, estratégia 1, textos cifrados, sem estoque; fila com prazo de criação + 24 h; trilha uma vez" do
    now = Time.current.change(usec: 0)
    on = Date.current - 55
    dose = call([ item("lot_number" => "  BCG123 ", "manufacturer_name" => "Fundação Ataulpho de Paiva", "place" => "Maternidade") ], now: now)
           .payload[:immunizations].sole
    expect(dose).to have_attributes(applied_at: on.in_time_zone.change(hour: 12), strategy: "1", immunobiological_code: "15", dose_code: "9",
                                    lot_number_text: "BCG123", manufacturer_text: "Fundação Ataulpho de Paiva", place_text: "Maternidade",
                                    vaccine_room_id: room.id, health_unit_id: room.health_unit_id, vaccinator_user_id: vaccinator.id,
                                    vaccinator_cbo: "322205", care_group: nil, route: nil, site: nil, vial_opening_id: nil)
    expect(StockMovement.where(kind: %w[immunization immunization_reversal])).to be_empty
    expect(RndsOutboxEntry.sole).to have_attributes(kind: "application", status: "pending", deadline_at: now + 24.hours)
    expect(VaccinationRecordCheck.count).to eq(0)
    expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(1)
    expect(DomainEvent.where(name: "vaccination.immunization_recorded").sole.payload)
      .to eq("immunization_id" => dose.id, "vaccine_room_id" => room.id, "user_id" => vaccinator.id)
    expect(DomainEvent.all.map(&:payload).to_json).not_to include("BCG123")
  end

  it "várias doses de uma vez; o card devolvido tem as doses" do
    result = call([ item, item("immunobiological_code" => "42", "dose_code" => "1", "applied_on" => (Date.current - 1).iso8601) ])
    expect(result.payload[:immunizations].size).to eq(2)
    expect(result.payload[:card][:immunizations].map { |imm| imm[:transcription] }).to eq([ true, true ])
  end

  it "todas as recusas de uma vez, por linha (items[i].<campo>); nada gravado" do
    result = call([ item("immunobiological_code" => "999", "applied_on" => (Date.current + 1).iso8601),
                    item("dose_code" => "x", "lot_number" => "L" * 41, "manufacturer_name" => "M" * 121, "place" => "P" * 121),
                    "x",
                    item("applied_on" => "2026-13-01"),
                    item("applied_on" => (Date.current - 62).iso8601) ])
    expect(result.reason).to eq(:invalid)
    expect(result.details[:problems]).to eq([
      { path: "items[0].immunobiological_code", error: "invalid_value" },
      { path: "items[0].applied_on", error: "applied_on_in_future" },
      { path: "items[1].dose_code", error: "invalid_value" },
      { path: "items[1].lot_number", error: "invalid_value" },
      { path: "items[1].manufacturer_name", error: "invalid_value" },
      { path: "items[1].place", error: "invalid_value" },
      { path: "items[2]", error: "invalid_request" },
      { path: "items[3].applied_on", error: "invalid_value" },
      { path: "items[4].applied_on", error: "applied_before_birth" }
    ])
    expect(result.details[:path]).to eq("items[0].immunobiological_code")
    expect(Immunization.count + RndsOutboxEntry.count + VaccinationRecordCheck.count).to eq(0)
  end

  it "limites (V14): lote 40, fabricante e local 120 aceitos; texto vazio vira nulo" do
    dose = call([ item("lot_number" => "L" * 40, "manufacturer_name" => "M" * 120, "place" => " ") ]).payload[:immunizations].sole
    expect(dose).to have_attributes(lot_number_text: "L" * 40, manufacturer_text: "M" * 120, place_text: nil)
  end

  it "items vazio, acima de 40 ou não lista → items invalid_request; close_check não booleano → close_check invalid_request" do
    [ [], Array.new(41) { item }, "x", nil ].each do |items|
      expect(call(items).details[:problems]).to eq([ { path: "items", error: "invalid_request" } ])
    end
    expect(call(Array.new(40) { item })).to be_ok
    expect(call([ item ], close_check: "true").details[:problems]).to eq([ { path: "close_check", error: "invalid_request" } ])
  end

  it "quem não tem vínculo de vacinador na unidade da sala → missing_role" do
    stranger = screener!(create_unit("UBS Outra"), cbo: "322205")
    expect(call([ item ], by: stranger).reason).to eq(:missing_role)
  end
end
