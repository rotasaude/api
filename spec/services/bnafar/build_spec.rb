require "rails_helper"

# Módulo 27b, Task 11 (contrato §3; Q8, Q14, Q25; R10, R12; Review Focus 2 e 4):
# a montagem da remessa de R. Por assunto, uma remessa por (dia, assunto,
# ambiente); um registro de posição por (CNES, item, parte de 20 lotes) e um de
# saída por movimento (link `exit`); lotes de envio de até 1.000; o estorno de
# saída aceita na janela vira um lote `delete` (link `deletion`), fora dela um
# link `late_reversal` sem chamada. A montagem é retomável por partes: rodar de
# novo, ou dois jobs juntos, não repete registro nem liga movimento duas vezes.
RSpec.describe Bnafar::Build, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:med) { Stock::Domain::MEDICATION }
  let(:vaccine) { Stock::Domain::IMMUNOBIOLOGICAL }
  let(:day) { Time.zone.today - 3 }

  def at(date, hour, min = 0) = date.in_time_zone.change(hour: hour, min: min)

  def build!(reference_on = day, domains: [ med ], environment: "production")
    travel_to(at(reference_on + 1, 1, 7)) do
      described_class.call(reference_on: reference_on, environment: environment, domains: domains, now: Time.current)
    end
  end

  def submission(subject, reference_on = day) = BnafarSubmission.find_by!(reference_on: reference_on, subject: subject, environment: "production")
  def items_of(record) = JSON.parse(record.payload).fetch("itens")

  describe "farmácia" do
    before { pharmacy_city! }
    let(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }

    def complete_lot!(location = central, quantity: "10", **over)
      losartana.update_columns(vmp_code: "@brasil1000")
      bnafar_complete!(stocked_lot!(location, item: losartana, quantity: quantity, **over), ampp_code: "@brasil20038375080")
    end

    it "45 lotes de um item num CNES → 3 registros (20, 20, 5) num lote post; a saída vazia nasce finished" do
      travel_to(at(day, 8)) { 45.times { complete_lot!(quantity: "2") } }

      result = build!
      expect(result).to be_ok
      position = submission("position")
      expect(result.payload[:submissions]).to contain_exactly(position, submission("exit"))
      expect(position.records.map { |record| items_of(record).size }.sort).to eq([ 5, 20, 20 ])
      expect(position.records.map(&:item_key).uniq).to eq([ "medication:#{losartana.id}" ])
      expect(position.batches.pluck(:operation, :status)).to eq([ %w[post queued] ])
      expect(position.records.pluck(:bnafar_batch_id).uniq).to eq([ position.batches.sole.id ])
      expect(position).to have_attributes(status: "queued", building_started_at: be_present)
      expect(submission("exit")).to have_attributes(status: "finished", finished_at: be_present)
      expect(submission("exit").records).to be_empty
      expect(DomainEvent.where(name: "bnafar_submission.queued").map(&:payload)).to eq([ { "bnafar_submission_id" => position.id } ])
      expect(BnafarSetting.current.started_on).to eq(day)
    end

    it "2.500 registros → 3 lotes de envio (1.000, 1.000, 500)" do
      lot = travel_to(at(day, 8)) { complete_lot! }
      row = Bnafar::Snapshot.call(reference_on: day, domains: [ med ], cutoff: (day + 1).in_time_zone).sole
      rows = Array.new(2_500) { |index| row.with(item_key: "medication:#{format('%04d', index)}") }
      allow(Bnafar::Snapshot).to receive(:call).and_return(rows)

      build!
      position = submission("position")
      expect(position.batches.map { |batch| batch.records.count }.sort).to eq([ 500, 1_000, 1_000 ])
      expect(position.records.count).to eq(2_500)
      expect(position.records.distinct.count(:origin_code)).to eq(2_500)
      expect(items_of(position.records.first).sole["codigoOrigem"]).to eq(lot.id)
    end

    it "item pendente fica fora e o resto vai (posição e saída)" do
      complete, incomplete = travel_to(at(day - 1, 8)) do
        [ complete_lot!(quantity: "20"), bnafar_complete!(stocked_lot!(central, item: losartana, quantity: "20"), unit_price_cents: nil) ]
      end
      sent, held = travel_to(at(day, 10)) { [ bnafar_loss!(central, complete, 2), bnafar_loss!(central, incomplete, 2) ] }

      build!
      position = submission("position").records.sole
      expect(items_of(position).map { |item| item["codigoOrigem"] }).to eq([ complete.id ])
      exit_record = submission("exit").records.sole
      expect(exit_record.movement_links.pluck(:stock_movement_id, :kind)).to eq([ [ sent.id, "exit" ] ])
      expect(JSON.parse(exit_record.payload).dig("caracterizacao", "tipoSaida")).to eq("S-PE")
      expect(BnafarMovementLink.where(stock_movement_id: held.id)).to be_empty
    end

    it "rodar duas vezes → uma remessa por assunto, sem registro repetido (Review Focus 2)" do
      lot = travel_to(at(day - 1, 8)) { complete_lot!(quantity: "20") }
      travel_to(at(day, 10)) { 2.times { bnafar_loss!(central, lot, 1) } }

      first = build!
      counts = [ BnafarSubmission.count, BnafarRecord.count, BnafarBatch.count, BnafarMovementLink.count ]
      second = build!
      expect([ BnafarSubmission.count, BnafarRecord.count, BnafarBatch.count, BnafarMovementLink.count ]).to eq(counts)
      expect(counts).to eq([ 2, 3, 2, 2 ])
      expect(second.payload[:submissions]).to match_array(first.payload[:submissions])
      expect(DomainEvent.where(name: "bnafar_submission.queued").count).to eq(2)
    end

    it "dois jobs ao mesmo tempo (o segundo entra entre as partes do primeiro) → uma remessa, cada movimento uma vez (Review Focus 2)" do
      stub_const("Bnafar::Limits::RECORDS_PER_BATCH", 1)
      lot = travel_to(at(day - 1, 8)) { complete_lot!(quantity: "20") }
      movements = travel_to(at(day, 10)) { Array.new(3) { bnafar_loss!(central, lot, 1) } }
      # O segundo job roda inteiro logo depois da primeira parte do primeiro
      # (o que o FOR UPDATE da remessa permite: a parte seguinte de cada um
      # recalcula o que falta sobre o que o outro já gravou).
      nested = false
      allow(BnafarMovementLink).to receive(:create!).and_wrap_original do |original, **attrs|
        link = original.call(**attrs)
        unless nested
          nested = true
          described_class.call(reference_on: day, environment: "production", domains: [ med ], now: Time.current)
        end
        link
      end

      build!
      exit_submission = submission("exit")
      expect(BnafarSubmission.where(reference_on: day, subject: "exit").count).to eq(1)
      expect(exit_submission.records.count).to eq(3)
      expect(BnafarMovementLink.where(stock_movement_id: movements.map(&:id)).group(:stock_movement_id).count.values).to eq([ 1, 1, 1 ])
      expect(exit_submission.status).to eq("queued")
      expect(DomainEvent.where(name: "bnafar_submission.queued", payload: { "bnafar_submission_id" => exit_submission.id }).count).to eq(1)
    end

    it "`building` pela metade é retomada sem repetir movimento" do
      stub_const("Bnafar::Limits::RECORDS_PER_BATCH", 1)
      lot = travel_to(at(day - 1, 8)) { complete_lot!(quantity: "20") }
      movements = travel_to(at(day, 10)) { Array.new(3) { bnafar_loss!(central, lot, 1) } }
      calls = 0
      allow(BnafarBatch).to receive(:create!).and_wrap_original do |original, **attrs|
        calls += 1 if attrs[:bnafar_submission].subject == "exit"
        raise "processo morto" if calls == 2

        original.call(**attrs)
      end

      expect { build! }.to raise_error(RuntimeError, "processo morto")
      half = submission("exit")
      expect(half.status).to eq("building")
      expect(half.records.count).to eq(1)

      allow(BnafarBatch).to receive(:create!).and_call_original
      build!
      expect(half.reload.status).to eq("queued")
      expect(half.records.count).to eq(3)
      expect(half.batches.count).to eq(3)
      expect(BnafarMovementLink.where(stock_movement_id: movements.map(&:id)).count).to eq(3)
      expect(half.records.map { |record| JSON.parse(record.payload).dig("itens", 0, "codigoOrigem") }).to match_array(movements.map(&:id))
    end

    it "sem nada a enviar → as duas remessas nascem finished e o started_on fica vazio" do
      build!
      expect(BnafarSubmission.pluck(:status)).to eq(%w[finished finished])
      expect(BnafarSetting.current.started_on).to be_nil
      expect(DomainEvent.where(name: "bnafar_submission.queued")).to be_empty
    end
  end

  describe "estorno de uso direto (Q14, Q25; Review Focus 4)" do
    before { vaccination_city! }
    let(:room) { vaccine_room!(create_unit("UBS Vacina E", cnes: "3333333")) }
    let!(:lot) { travel_to(at(day - 40, 8)) { vaccine_lot!(room, code: "42", doses: 10) } }

    def dose!(applied_at:) = create_immunization!(room, stock_lot: lot, immunobiological_code: lot.immunobiological_code, applied_at: applied_at)

    def apply!(dose) = Pharmacy::Ledger.record!(location: room.stock_location, lot: lot, kind: "immunization", quantity: 1,
                                                by: pharmacy_admin!, document: dose)

    def reverse!(dose) = Pharmacy::Ledger.record!(location: room.stock_location, lot: lot, kind: "immunization_reversal", quantity: 1,
                                                  by: pharmacy_admin!, document: dose)

    # Aplicação enviada e aceita em `sent_at` (dia ou instante); estorno em R.
    def reversal_of_dose_sent!(sent_at, bnafar_code: rand(1..999_999))
      sent_at = at(sent_at, 9) if sent_at.is_a?(Date)
      dose = dose!(applied_at: sent_at - 1.day)
      original = travel_to(sent_at - 1.day) { apply!(dose) }
      link = travel_to(sent_at) { bnafar_link!(original, bnafar_code: bnafar_code) }
      reversal = travel_to(at(day, 10)) { reverse!(dose) }
      [ link, reversal ]
    end

    it "dose aceita ontem e estornada hoje → lote delete com o bnafar_code e link deletion" do
      link, reversal = reversal_of_dose_sent!(day - 1)
      original = link.bnafar_record

      build!(domains: [ vaccine ])
      deletion = BnafarBatch.find_by!(operation: "delete")
      expect(deletion).to have_attributes(bnafar_submission_id: original.bnafar_submission_id, status: "queued")
      expect(original.reload.deletion_batch_id).to eq(deletion.id)
      expect(original.deleted_at).to be_nil
      expect(BnafarMovementLink.find_by!(stock_movement_id: reversal.id)).to have_attributes(kind: "deletion", bnafar_record_id: original.id)
      expect(original.bnafar_submission.reload.status).to eq("finished") # R10: o delete não reabre a remessa
    end

    it "dose aceita há 31 dias → link late_reversal e nenhum lote" do
      link, reversal = reversal_of_dose_sent!(day - 31)

      build!(domains: [ vaccine ])
      expect(BnafarBatch.where(operation: "delete")).to be_empty
      expect(link.bnafar_record.reload.deletion_batch_id).to be_nil
      expect(BnafarMovementLink.find_by!(stock_movement_id: reversal.id)).to have_attributes(kind: "late_reversal", bnafar_record_id: link.bnafar_record_id)
    end

    it "janela pelo sent_at (Q25): enviada há 30 dias menos 1 h ainda apaga" do
      link, = reversal_of_dose_sent!(at(day + 1, 1, 7) - 30.days + 1.hour)

      build!(domains: [ vaccine ])
      expect(BnafarBatch.where(operation: "delete").count).to eq(1)
      expect(Bnafar::Window.correctable_until(link.bnafar_record.reload)).to eq(link.bnafar_record.sent_at + 30.days)
    end

    it "original ainda não aceito (pending) → sem DELETE: late_reversal (a fotografia corrige)" do
      link, reversal = reversal_of_dose_sent!(day - 1)
      record = BnafarRecord.create!(bnafar_submission: link.bnafar_record.bnafar_submission, origin_code: SecureRandom.uuid, subject: "exit",
                                    stock_location_id: room.stock_location.id, item_key: "test:pending", payload: "{}")
      other = travel_to(at(day - 2, 9)) { dose!(applied_at: at(day - 2, 9)).then { |dose| [ dose, apply!(dose) ] } }
      BnafarMovementLink.create!(stock_movement: other.last, bnafar_record: record, kind: "exit")
      late = travel_to(at(day, 11)) { reverse!(other.first) }

      build!(domains: [ vaccine ])
      expect(BnafarBatch.where(operation: "delete").sole.id).to eq(link.bnafar_record.reload.deletion_batch_id)
      expect(record.reload.deletion_batch_id).to be_nil
      expect(BnafarMovementLink.find_by!(stock_movement_id: late.id).kind).to eq("late_reversal")
      expect(BnafarMovementLink.find_by!(stock_movement_id: reversal.id).kind).to eq("deletion")
    end

    it "aceito sem bnafar_code (MSG15) → late_reversal: não há código para o DELETE" do
      _link, reversal = reversal_of_dose_sent!(day - 1, bnafar_code: nil)

      build!(domains: [ vaccine ])
      expect(BnafarBatch.where(operation: "delete")).to be_empty
      expect(BnafarMovementLink.find_by!(stock_movement_id: reversal.id).kind).to eq("late_reversal")
    end
  end
end
