require "rails_helper"

# Módulo 29, Task 9 (ADR 0047, Desvios 7, 9, 12 e 13; §15 V6, V7; Review
# Focus 1 e 3): cancelamento da dose, com a substituição na mesma transação.
RSpec.describe Vaccination::CancelImmunization do
  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room, role: "vaccinator") }
  let(:lead) { room_member!(room, role: "room_lead", cbo: "223505") }
  let(:child) { vaccine_patient!(birth_date: Date.current - 61, sex: "female") }
  let(:lot) { vaccine_lot!(room, code: "42", doses: 5) }
  let(:reason) { "Dose registrada como D1 por engano" }

  def replacement_attrs(dose, **over)
    { "immunobiological_code" => dose.immunobiological_code, "dose_code" => dose.dose_code, "strategy" => "1", "care_group" => "121",
      "route" => "3", "site" => "18", "maternal_condition" => "1", "applied_at" => dose.applied_at.iso8601,
      "lot_id" => dose.stock_lot_id, "vial_id" => dose.vial_opening_id }.compact.merge(over.transform_keys(&:to_s))
  end

  def cancel(dose, by: lead, replacement: nil, reason: self.reason)
    described_class.call(immunization: dose, reason: reason, replacement: replacement, by: by)
  end

  def kinds(dose) = RndsOutboxEntry.where(immunization_id: dose.id).pluck(:kind)

  it "Review Focus 1: unidose cancelada e substituída pelo mesmo lote: o lote perde uma dose só" do
    dose = record!(room, child, lot: lot, by: vaccinator)
    result = cancel(dose, replacement: replacement_attrs(dose, dose_code: "2", override_reason: "Correção da dose registrada antes"))
    expect(result).to be_ok
    expect(balance_of(room.stock_location, lot)).to eq(4)
    expect(result.payload[:replacement].replaces_id).to eq(dose.id)
    # Original nunca tentado: não vai à RNDS e não nasce cancelamento (Fix round 1, I3).
    expect(kinds(dose)).to eq(%w[application])
    expect(StockMovement.where(kind: "immunization_reversal").sole).to have_attributes(quantity: 1, immunization_id: dose.id, stock_lot_id: lot.id,
                                                                                        stock_location_id: room.stock_location_id)
  end

  it "Review Focus 1: multidose cancelada não devolve dose ao lote; o frasco volta a ter a dose" do
    vial = open_vial!(room, lot: vaccine_lot!(room, code: "22", doses: 10))
    dose = record!(room, child, lot: vial.stock_lot, vial: vial)
    expect(vial.reload.doses_left).to eq(9)
    expect(cancel(dose)).to be_ok
    expect(StockMovement.where(kind: "immunization_reversal")).to be_empty
    expect(vial.reload.doses_left).to eq(10)
  end

  it "grava os três campos uma vez, com o motivo cifrado; evento só com ids; situação recalculada; trilha" do
    dose = record!(room, child, lot: lot, by: vaccinator)
    expect(VaccinationStatus.find_by(patient_id: child.id, series: "penta").doses_applied).to eq(1)
    seen = DomainEvent.pluck(:id)
    result = cancel(dose, by: vaccinator)
    events = DomainEvent.where.not(id: seen)
    expect(result.payload).to include(replacement: nil)
    expect(dose.reload).to have_attributes(cancelled_by_user_id: vaccinator.id, cancel_reason: reason)
    expect(dose.cancelled_at).to be_present
    raw = Immunization.connection.select_value("SELECT cancel_reason FROM immunizations WHERE id = #{Immunization.connection.quote(dose.id)}")
    expect(raw).not_to include("engano")
    expect(VaccinationStatus.find_by(patient_id: child.id, series: "penta")&.doses_applied.to_i).to eq(0)
    expect(events.where(name: "vaccination.immunization_cancelled").sole.payload)
      .to eq("immunization_id" => dose.id, "vaccine_room_id" => room.id, "user_id" => vaccinator.id, "replacement_id" => nil)
    expect(events.where(name: "clinical_record.viewed").sole.payload).to include("patient_id" => child.id, "access" => "vaccination")
    expect(DomainEvent.all.map(&:payload).to_json).not_to include("engano")
  end

  it "autor ou room_lead da sala; outro vacinador → cancel_not_allowed; já cancelada → already_cancelled" do
    dose = record!(room, child, lot: lot, by: vaccinator)
    expect(cancel(dose, by: room_member!(room)).reason).to eq(:cancel_not_allowed)
    expect(cancel(dose, by: room_member!(other = vaccine_room!, role: "room_lead", cbo: "223505")).reason).to eq(:cancel_not_allowed)
    expect(other).to be_present
    expect(cancel(dose, by: lead)).to be_ok
    expect(cancel(dose.reload, by: vaccinator).reason).to eq(:already_cancelled)
  end

  it "motivo fora de 10..500 → invalid_reason, nada muda" do
    dose = record!(room, child, lot: lot, by: vaccinator)
    [ "curto", "x" * 501, nil, 42 ].each do |bad|
      result = cancel(dose, reason: bad)
      expect([ result.reason, result.details[:path] ]).to eq([ :invalid_reason, "reason" ])
    end
    expect(dose.reload.cancelled_at).to be_nil
    expect(cancel(dose, reason: "x" * 500)).to be_ok
  end

  it "V6: substituição recusada não cancela nada; os problemas vêm com path replacement.<campo>" do
    dose = record!(room, child, lot: lot, by: vaccinator)
    result = cancel(dose, replacement: replacement_attrs(dose, route: "99", lot_id: vaccine_lot!(room, code: "24").id))
    expect(result.reason).to eq(:invalid)
    expect(result.details[:path]).to eq("replacement.route")
    expect(result.details[:problems]).to eq([ { path: "replacement.route", error: "invalid_value" },
                                              { path: "replacement.lot_id", error: "lot_product_mismatch" } ])
    expect(dose.reload.cancelled_at).to be_nil
    expect(StockMovement.where(kind: "immunization_reversal")).to be_empty
    expect(balance_of(room.stock_location, lot)).to eq(4)
    expect(kinds(dose)).to eq(%w[application])
    expect(Immunization.count).to eq(1)
    expect(DomainEvent.where(name: "vaccination.immunization_cancelled")).to be_empty
  end

  it "substituição: corpo que não é objeto → replacement invalid_request; paciente diferente → replacement.patient_id" do
    dose = record!(room, child, lot: lot, by: vaccinator)
    expect(cancel(dose, replacement: "x").details[:problems]).to eq([ { path: "replacement", error: "invalid_request" } ])
    other = vaccine_patient!(birth_date: Date.current - 61)
    expect(cancel(dose, replacement: replacement_attrs(dose, patient_id: other.id)).details[:problems])
      .to eq([ { path: "replacement.patient_id", error: "invalid_value" } ])
    expect(cancel(dose, replacement: replacement_attrs(dose, patient_id: child.id, dose_code: "2",
                                                             override_reason: "Correção da dose registrada antes"))).to be_ok
  end

  it "substituta pega a última dose do lote que a reversão devolveu" do
    single = vaccine_lot!(room, code: "42", doses: 1)
    dose = record!(room, child, lot: single, by: vaccinator)
    expect(balance_of(room.stock_location, single)).to eq(0)
    result = cancel(dose, replacement: replacement_attrs(dose, dose_code: "2", override_reason: "Correção da dose registrada antes"))
    expect(result).to be_ok
    expect(balance_of(room.stock_location, single)).to eq(0)
  end

  describe "fila RNDS (V7, Desvio 12)" do
    it "I3: original pending sem tentativa (inclusive envio desligado) → nenhum cancelamento; a application fica withdrawn" do
      dose = record!(room, child, lot: lot, by: vaccinator)
      application = RndsOutboxEntry.find_by(immunization_id: dose.id)
      expect(application.attempted?).to be(false)
      expect(RndsOutboxEntry.withdrawn).to be_empty
      expect(cancel(dose)).to be_ok
      expect(kinds(dose)).to eq(%w[application])
      expect(RndsOutboxEntry.withdrawn.pluck(:id)).to eq([ application.id ])
      expect(RndsOutboxEntry.not_withdrawn.where(immunization_id: dose.id)).to be_empty
      expect(Vaccination::Pending.counts(room, rnds_enabled: true)).to include(late: 0)
    end

    it "I3: original blocked → nenhum cancelamento; withdrawn" do
      dose = record!(room, child, lot: lot, by: vaccinator)
      RndsOutboxEntry.find_by(immunization_id: dose.id).update!(status: "blocked", block_reason: "patient_without_cns_or_cpf",
                                                                 first_attempt_at: 1.hour.ago)
      cancel(dose)
      expect(kinds(dose)).to eq(%w[application])
      expect(RndsOutboxEntry.withdrawn.where(immunization_id: dose.id).count).to eq(1)
    end

    it "I3: dose ativa nunca é withdrawn" do
      dose = record!(room, child, lot: lot, by: vaccinator)
      RndsOutboxEntry.find_by(immunization_id: dose.id).update!(status: "blocked", block_reason: "patient_without_cns_or_cpf")
      expect(RndsOutboxEntry.withdrawn).to be_empty
      expect(RndsOutboxEntry.not_withdrawn.where(immunization_id: dose.id).count).to eq(1)
    end

    it "I3: original pending depois de uma tentativa (timeout) → cancellation pending com prazo de criação + 24 h" do
      dose = record!(room, child, lot: lot, by: vaccinator, applied_at: 3.hours.ago.iso8601)
      RndsOutboxEntry.find_by(immunization_id: dose.id).update!(first_attempt_at: 1.hour.ago, attempts: 1)
      now = Time.current.change(usec: 0)
      described_class.call(immunization: dose, reason: reason, replacement: nil, by: lead, now: now)
      expect(RndsOutboxEntry.find_by(immunization_id: dose.id, kind: "cancellation"))
        .to have_attributes(status: "pending", payload: nil, deadline_at: now + 24.hours, next_attempt_at: now)
    end

    it "original sending → cancellation" do
      dose = record!(room, child, lot: lot, by: vaccinator)
      RndsOutboxEntry.find_by(immunization_id: dose.id).update!(status: "sending")
      cancel(dose)
      expect(kinds(dose)).to match_array(%w[application cancellation])
    end

    it "original accepted → cancellation" do
      dose = record!(room, child, lot: lot, by: vaccinator)
      RndsOutboxEntry.find_by(immunization_id: dose.id).update!(status: "accepted", accepted_at: Time.current, rnds_id: "rnds-1")
      cancel(dose)
      expect(kinds(dose)).to match_array(%w[application cancellation])
    end

    %w[rejected failed].each do |status|
      it "original #{status} → nenhuma entrada de cancelamento" do
        dose = record!(room, child, lot: lot, by: vaccinator)
        RndsOutboxEntry.find_by(immunization_id: dose.id).update!(status: status, error: "Recusada")
        expect(cancel(dose)).to be_ok
        expect(kinds(dose)).to eq(%w[application])
      end
    end

    it "Review Focus 3: original recusado (422) e cancelado: nenhum cancelamento nasce, a substituta entra na fila e a pendência some" do
      dose = record!(room, child, lot: lot, by: vaccinator)
      RndsOutboxEntry.find_by(immunization_id: dose.id).update!(status: "rejected", error: "422 Unprocessable Entity")
      expect(Vaccination::Pending.scope(room, rnds_enabled: true).map(&:immunization_id)).to eq([ dose.id ])
      result = cancel(dose, replacement: replacement_attrs(dose, dose_code: "2", override_reason: "Correção da dose registrada antes"))
      replacement = result.payload[:replacement]
      expect(kinds(dose)).to eq(%w[application])
      expect(RndsOutboxEntry.where(immunization_id: replacement.id).pluck(:kind, :status)).to eq([ %w[application pending] ])
      expect(Vaccination::Pending.scope(room, rnds_enabled: true).map(&:immunization_id)).not_to include(dose.id)
    end
  end

  describe "transcrição" do
    let(:transcribed) do
      Vaccination::RecordTranscription.call(room: room, patient: child, close_check: false, by: vaccinator,
                                            items: [ { "immunobiological_code" => "15", "dose_code" => "9", "applied_on" => (Date.current - 55).iso8601 } ])
                                      .payload[:immunizations].sole
    end

    it "cancelada sem estoque; substituída por outro item de transcrição" do
      result = cancel(transcribed, replacement: { "immunobiological_code" => "15", "dose_code" => "9", "applied_on" => (Date.current - 54).iso8601,
                                                  "place" => "Maternidade" })
      expect(result).to be_ok
      expect(result.payload[:replacement]).to have_attributes(transcription: true, replaces_id: transcribed.id, place_text: "Maternidade",
                                                              stock_lot_id: nil)
      expect(StockMovement.where(kind: "immunization_reversal")).to be_empty
    end

    it "I1: substituição de transcrição grava uma trilha pela pessoa" do
      transcribed
      seen = DomainEvent.pluck(:id)
      cancel(transcribed, replacement: { "immunobiological_code" => "15", "dose_code" => "9", "applied_on" => (Date.current - 54).iso8601 })
      expect(DomainEvent.where.not(id: seen).where(name: "clinical_record.viewed").map(&:payload))
        .to contain_exactly(include("patient_id" => child.id, "user_id" => lead.id, "access" => "vaccination"))
    end

    it "I1: substituição comum grava uma trilha (a do RecordImmunization), não duas" do
      dose = record!(room, child, lot: lot, by: vaccinator)
      seen = DomainEvent.pluck(:id)
      cancel(dose, replacement: replacement_attrs(dose, dose_code: "2", override_reason: "Correção da dose registrada antes"))
      expect(DomainEvent.where.not(id: seen).where(name: "clinical_record.viewed").count).to eq(1)
    end

    it "item de substituição inválido → replacement.applied_on" do
      result = cancel(transcribed, replacement: { "immunobiological_code" => "15", "dose_code" => "9", "applied_on" => (Date.current + 1).iso8601 })
      expect(result.details[:problems]).to eq([ { path: "replacement.applied_on", error: "applied_on_in_future" } ])
      expect(transcribed.reload.cancelled_at).to be_nil
    end
  end
end
