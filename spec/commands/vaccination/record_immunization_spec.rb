require "rails_helper"

# Módulo 29, Task 8 (ADR 0047, Desvios 9, 12, 13 e 20; contrato §5; §15 V5,
# V14, V20; Review Focus 4): registro da dose aplicada na sala.
RSpec.describe Vaccination::RecordImmunization do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room, role: "vaccinator") }
  let(:child) { vaccine_patient!(birth_date: Date.current - 61, sex: "female") }
  let(:lot) { vaccine_lot!(room, code: "42", doses: 5) }

  def attrs(**over) = { "immunobiological_code" => "42", "dose_code" => "1", "strategy" => "1", "care_group" => "121", "route" => "3", "site" => "18",
                        "maternal_condition" => "1", "applied_at" => Time.current.iso8601, "lot_id" => lot.id }.merge(over.transform_keys(&:to_s))
  def call(**over) = described_class.call(room: room, patient: child, attrs: attrs(**over), by: vaccinator)
  def errors(result) = result.details[:problems].map { |p| p[:error] }

  it "grava a dose, tira 1 do lote unidose, materializa a situação e entra na fila" do
    result = call
    dose = result.payload[:immunization]
    expect(dose).to have_attributes(vaccinator_cbo: "322205", transcription: false, calendar_version: "2026.1")
    expect(balance_of(room.stock_location, lot)).to eq(4)
    expect(VaccinationStatus.find_by(patient_id: child.id, series: "penta")).to have_attributes(doses_applied: 1, next_dose_code: "2")
    expect(RndsOutboxEntry.sole).to have_attributes(kind: "application", status: "pending", payload: nil)
  end

  it "fila: pending, próxima tentativa agora, prazo applied_at + 24 h; movimento immunization com a dose como documento; evento só com ids; trilha" do
    applied = 2.hours.ago.change(usec: 0)
    now = Time.current.change(usec: 0)
    dose = described_class.call(room: room, patient: child, attrs: attrs(applied_at: applied.iso8601), by: vaccinator, now: now).payload[:immunization]
    expect(RndsOutboxEntry.sole).to have_attributes(immunization_id: dose.id, next_attempt_at: now, deadline_at: applied + 24.hours, attempts: 0)
    expect(StockMovement.where(kind: "immunization").sole).to have_attributes(quantity: -1, immunization_id: dose.id, stock_lot_id: lot.id)
    expect(DomainEvent.where(name: "vaccination.immunization_recorded").sole.payload)
      .to eq("immunization_id" => dose.id, "vaccine_room_id" => room.id, "user_id" => vaccinator.id)
    expect(DomainEvent.where(name: "clinical_record.viewed").sole.payload)
      .to include("patient_id" => child.id, "access" => "vaccination", "person_ref" => "patient:#{child.id}")
  end

  it "junta todas as recusas" do
    other = vaccine_lot!(vaccine_room!, code: "42")
    result = call(applied_at: 1.hour.from_now.iso8601, lot_id: other.id, route: "99")
    expect(errors(result)).to eq(%w[invalid_value applied_at_in_future lot_not_in_room])
    expect(result.details[:problems].first).to eq({ path: "route", error: "invalid_value" })
    expect(Immunization.count).to eq(0)
  end

  it "intervalo curto pede motivo (overridable, §15 V5); com motivo grava e guarda o motivo" do
    call
    expect(call(dose_code: "2").details[:problems]).to eq([ { path: "dose_code", error: "interval_too_short", overridable: true } ])
    result = call(dose_code: "2", override_reason: "Viagem da família para fora do país")
    expect(result).to be_ok
    expect(result.payload[:immunization].reload.override_reason).to eq("Viagem da família para fora do país")
  end

  it "idade fora da faixa pede motivo; motivo fora de 10..500 → invalid_reason (V14)" do
    young = vaccine_patient!(birth_date: Date.current - 20)
    result = described_class.call(room: room, patient: young, attrs: attrs, by: vaccinator)
    expect(result.details[:problems]).to eq([ { path: "dose_code", error: "age_out_of_range", overridable: true } ])
    [ "curto", "x" * 501, 42 ].each do |reason|
      refused = described_class.call(room: room, patient: young, attrs: attrs(override_reason: reason), by: vaccinator)
      # Motivo inválido não vale como motivo: o aviso volta junto.
      expect(refused.details[:problems]).to eq([ { path: "override_reason", error: "invalid_reason" },
                                                 { path: "dose_code", error: "age_out_of_range", overridable: true } ])
    end
    expect(described_class.call(room: room, patient: young, attrs: attrs(override_reason: "x" * 500), by: vaccinator)).to be_ok
  end

  it "dose fora do calendário só na estratégia de rotina (1)" do
    expect(errors(call(dose_code: "57"))).to eq(%w[dose_not_in_calendar])
    expect(call(dose_code: "57", strategy: "2")).to be_ok
  end

  it "terminologias: campo ausente ou fora da lista → invalid_value por campo; grupo de atendimento inativo recusado (V20)" do
    result = call(immunobiological_code: "999", dose_code: nil, strategy: "x", care_group: "10", site: 18, applied_at: "2026-11-02T10:00:00")
    expect(result.details[:problems].map { |p| p[:path] }).to eq(%w[immunobiological_code dose_code strategy care_group site applied_at])
    expect(errors(result).uniq).to eq(%w[invalid_value])
  end

  it "lote vencido no dia da aplicação; lote de outra vacina (lot_product_mismatch, V22); sem saldo" do
    expired = vaccine_lot!(room, code: "42", expires_on: Date.current - 1)
    expect(errors(call(lot_id: expired.id))).to eq(%w[lot_expired])
    vip_lot = vaccine_lot!(room, code: "24")
    expect(call(lot_id: vip_lot.id).details[:problems]).to eq([ { path: "lot_id", error: "lot_product_mismatch" } ])
    expect(call(lot_id: nil).details[:problems]).to eq([ { path: "lot_id", error: "invalid_value" } ])
    expect(call(lot_id: SecureRandom.uuid).details[:problems]).to eq([ { path: "lot_id", error: "lot_not_in_room" } ])
    empty = vaccine_lot!(room, code: "42", doses: 1)
    expect(call(lot_id: empty.id)).to be_ok
    expect(call(lot_id: empty.id).details[:problems]).to eq([ { path: "lot_id", error: "insufficient_balance" } ])
  end

  # V27: só mulher de 10 a 49 anos completos na data da aplicação (dia da
  # cidade, aritmética de calendário). Fora disso pode vir nula e grava nula.
  describe "maternal_condition_required (V27)" do
    let(:on) { Time.current.in_time_zone.to_date }

    def required?(birth, sex: "female")
      person = vaccine_patient!(birth_date: birth, sex: sex)
      result = described_class.call(room: room, patient: person, attrs: attrs.except("maternal_condition"), by: vaccinator)
      result.failure? && errors(result).include?("maternal_condition_required")
    end

    it "véspera dos 10 anos não exige; aniversário dos 10 exige" do
      expect(required?(on.advance(years: -10) + 1)).to be(false)
      expect(required?(on.advance(years: -10))).to be(true)
    end

    it "véspera dos 50 exige; aniversário dos 50 não exige" do
      expect(required?(on.advance(years: -50) + 1)).to be(true)
      expect(required?(on.advance(years: -50))).to be(false)
    end

    it "menino não exige; menina de 2 meses grava com a condição nula" do
      expect(required?(on.advance(years: -25), sex: "male")).to be(false)
      result = described_class.call(room: room, patient: child, attrs: attrs.except("maternal_condition"), by: vaccinator)
      expect(result).to be_ok
      expect(result.payload[:immunization].maternal_condition).to be_nil
    end

    it "a faixa é a da data da aplicação, não a de hoje" do
      woman = vaccine_patient!(birth_date: on.advance(years: -10) - 1, sex: "female")
      result = described_class.call(room: room, patient: woman, by: vaccinator,
                                    attrs: attrs(applied_at: 3.days.ago.iso8601).except("maternal_condition"))
      expect(errors(result)).not_to include("maternal_condition_required")
    end
  end

  describe "multidose" do
    let(:vip) { vaccine_lot!(room, code: "22", doses: 20) }
    let(:vial) { open_vial!(room, lot: vip) }
    def vip_call(**over) = call(immunobiological_code: "22", lot_id: vip.id, **over)

    it "multidose sem frasco → vial_required; frasco de outro lote → vial_lot_mismatch" do
      expect(vip_call.details[:problems]).to include({ path: "vial_id", error: "vial_required" })
      other = open_vial!(room, lot: vaccine_lot!(room, code: "22", doses: 10))
      expect(vip_call(vial_id: other.id).details[:problems]).to eq([ { path: "vial_id", error: "vial_lot_mismatch" } ])
    end

    it "com frasco: grava sem movimento de estoque e conta a dose no frasco" do
      expect(vip_call(vial_id: vial.id)).to be_ok
      expect(StockMovement.where(kind: "immunization")).to be_empty
      expect(balance_of(room.stock_location, vip)).to eq(10)
      expect(vial.reload.doses_used).to eq(1)
    end

    it "frasco vazio → vial_empty; vencido → vial_expired; descartado → vial_closed_out (V22); frasco de outra sala ou unidose com frasco → invalid_value" do
      apply_from_vial!(vial, count: 10)
      expect(errors(vip_call(vial_id: vial.id))).to eq(%w[vial_empty])
      fresh = open_vial!(room, lot: vip)
      travel_to(fresh.expires_at + 1.minute) do
        expect(errors(call(immunobiological_code: "22", lot_id: vip.id, vial_id: fresh.id, applied_at: Time.current.iso8601))).to eq(%w[vial_expired])
      end
      spare = vaccine_lot!(room, code: "22", doses: 10)
      discarded = open_vial!(room, lot: spare)
      Vaccination::CloseOutVial.call(vial: discarded, reason: "Frasco caiu no chão da sala", by: room_member!(room, role: "room_lead", cbo: "223505"))
      expect(errors(vip_call(lot_id: spare.id, vial_id: discarded.id))).to eq(%w[vial_closed_out])
      foreign = open_vial!(other_room = vaccine_room!, lot: vaccine_lot!(other_room, code: "22"))
      expect(vip_call(vial_id: foreign.id).details[:problems]).to eq([ { path: "vial_id", error: "invalid_value" } ])
      expect(call(vial_id: fresh.id).details[:problems]).to eq([ { path: "vial_id", error: "invalid_value" } ])
    end

    it "Review Focus 4: excursão aberta bloqueia o lote também com o frasco já aberto (lot_blocked)" do
      vial
      lot_block!(room.stock_location, vip)
      expect(errors(vip_call(vial_id: vial.id))).to eq(%w[lot_blocked])
      lot_block!(room.stock_location, lot)
      expect(errors(call)).to eq(%w[lot_blocked])
      expect(Immunization.count).to eq(0)
    end
  end

  it "quem não tem vínculo de vacinador na unidade da sala → missing_role" do
    stranger = screener!(create_unit("UBS Outra"), cbo: "322205")
    expect(described_class.call(room: room, patient: child, attrs: attrs, by: stranger).reason).to eq(:missing_role)
  end

  describe Rnds::Enqueue do
    it "idempotente pelo índice único; cancelamento e transcrição com prazo de created_at + 24 h" do
      now = Time.current.change(usec: 0)
      dose = create_immunization!(room, applied_at: now - 3.days)
      first = described_class.call(dose, kind: "application", now: now)
      expect(first).to have_attributes(status: "pending", deadline_at: now - 3.days + 24.hours, next_attempt_at: now)
      expect(described_class.call(dose, kind: "application", now: now)).to be_nil
      expect(described_class.call(dose, kind: "cancellation", now: now)).to have_attributes(deadline_at: now + 24.hours)
      expect(RndsOutboxEntry.count).to eq(2)
      expect { described_class.call(dose, kind: "other") }.to raise_error(ArgumentError)
    end
  end
end
