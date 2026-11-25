require "rails_helper"

# Módulo 27b, Task 10 (Valores 5 e 6; Q13, Q14; Review Focus 1): as saídas do
# dia R são os movimentos negativos CRIADOS em R, fora dos ignorados e sem link;
# o estorno no mesmo dia compensa antes do envio; o estorno de saída já ligada
# vira Reversal; o destino segue o Valor 5.
RSpec.describe Bnafar::Exits, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:med) { Stock::Domain::MEDICATION }
  let(:vaccine) { Stock::Domain::IMMUNOBIOLOGICAL }
  let(:day) { Time.zone.today - 2 }

  def at(date, hour) = date.in_time_zone.change(hour: hour)
  def exits(date = day, domains: [ med, vaccine ]) = described_class.call(day: date, domains: domains, from: date.in_time_zone, to: (date + 1).in_time_zone)

  describe "farmácia" do
    before { pharmacy_city! }
    let(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }
    let!(:lot) { travel_to(at(day - 1, 8)) { stocked_lot!(central, item: losartana, quantity: "50") } }

    def dispensing!(location, lot, quantity)
      patient = registry_patient!
      keeper = pharmacy_admin!
      external = ExternalPrescription.create!(patient: patient, stock_location: location, prescriber_name: "Dra. Beltrana", council: "CRM",
                                              council_state: "PR", council_number: "12345", issued_on: Date.current, recorded_by_user: keeper)
      prescribed = ExternalPrescriptionItem.create!(external_prescription: external, position: 1, catalog_item_id: lot.catalog_item_id,
                                                    catmat_code: lot.catmat_code, quantity: quantity, quantity_unit: "comprimido",
                                                    dosage_instructions: "1 comprimido ao dia")
      dispensation = Dispensation.create!(stock_location: location, patient: patient, external_prescription: external, dispensed_by_user: keeper,
                                          dispensed_by_role: "pharmacist", dispensed_at: Time.current)
      item = DispensationItem.create!(dispensation: dispensation, external_prescription_item: prescribed, catalog_item_id: lot.catalog_item_id,
                                      stock_lot: lot, quantity: quantity)
      Pharmacy::Ledger.record!(location: location, lot: lot, kind: "dispensing", quantity: quantity, by: keeper, document: item)
    end

    it "dispensação nunca" do
      unit = unit_location!(create_unit("UBS Dispensa", cnes: "7654321"))
      stocked = travel_to(at(day - 1, 8)) { stocked_lot!(unit, item: losartana, quantity: "20") }
      travel_to(at(day, 10)) { dispensing!(unit, stocked, 4) }

      expect(exits).to eq(exits: [], reversals: [])
    end

    it "perda → S-PE com o CNES do próprio estabelecimento; quantidade inteira positiva" do
      movement = travel_to(at(day, 10)) { bnafar_loss!(central, lot, 3) }

      row = exits[:exits].sole
      expect(row).to have_attributes(movement: movement, cnes: "1234567", type: "A", exit_type: "S-PE", destination: "1234567",
                                     lot: lot, quantity: 3)
    end

    it "transferência → S-T com o CNES do destino; destino sem CNES → pendência" do
      with_cnes = unit_location!(create_unit("UBS Com CNES", cnes: "7654321"))
      without = unit_location!(create_unit("UBS Sem CNES"))
      travel_to(at(day, 10)) do
        [ with_cnes, without ].each do |to|
          result = Pharmacy::SendTransfer.call(from: central, to: to, items: [ { "lot_id" => lot.id, "quantity" => "5" } ], by: pharmacy_admin!)
          raise result.inspect if result.failure?
        end
      end

      rows = exits[:exits]
      expect(rows.map { |row| [ row.exit_type, row.destination, row.quantity ] }).to contain_exactly([ "S-T", "7654321", 5 ], [ "S-T", nil, 5 ])
      pendency = Bnafar::Pendencies.call(rows: rows).select { |found| found.code == "location_without_cnes" }.sole
      expect(pendency).to have_attributes(code: "location_without_cnes", stock_location_id: without.id, location_name: without.name,
                                          stock_lot_id: lot.id, fields: [ "cnes" ])
    end

    it "saída externa → o tipo e o destino informados" do
      external = StockExternalExit.create!(stock_location: central, exit_type: "S-D", destination_kind: "cnpj", destination_code: "12ABC34501DE35",
                                           reason: "Doação à entidade filantrópica", recorded_by_user: pharmacy_admin!, recorded_at: Time.current)
      travel_to(at(day, 11)) do
        Pharmacy::Ledger.record!(location: central, lot: lot, kind: "external_exit", quantity: 2, by: pharmacy_admin!, document: external)
      end

      expect(exits[:exits].sole).to have_attributes(exit_type: "S-D", destination: "12ABC34501DE35", quantity: 2)
    end

    it "movimento já ligado fica fora; domínio desligado fica fora" do
      movement = travel_to(at(day, 10)) { bnafar_loss!(central, lot, 3) }

      expect(exits(domains: [ vaccine ])[:exits]).to eq([])
      bnafar_link!(movement)
      expect(exits[:exits]).to eq([])
    end
  end

  describe "sala de vacina" do
    before { vaccination_city! }
    let(:room) { vaccine_room!(create_unit("UBS Vacina R", cnes: "3333333")) }
    let!(:lot) { travel_to(at(day - 3, 8)) { vaccine_lot!(room, code: "42", doses: 10) } }

    def dose!(applied_at:)
      create_immunization!(room, stock_lot: lot, immunobiological_code: lot.immunobiological_code, applied_at: applied_at)
    end

    def apply!(dose, at:) = Pharmacy::Ledger.record!(location: room.stock_location, lot: lot, kind: "immunization", quantity: 1,
                                                        by: pharmacy_admin!, document: dose, at: at)

    def reverse!(dose) = Pharmacy::Ledger.record!(location: room.stock_location, lot: lot, kind: "immunization_reversal", quantity: 1,
                                                  by: pharmacy_admin!, document: dose)

    it "aplicação criada em R+1 com recorded_at em R vai em R+1 (Review Focus 1)" do
      dose = dose!(applied_at: at(day, 15))
      movement = travel_to(at(day + 1, 9)) { apply!(dose, at: at(day, 15)) }

      expect(exits(day)[:exits]).to eq([])
      row = exits(day + 1)[:exits].sole
      expect(row).to have_attributes(movement: movement, exit_type: "S-CA", cnes: "3333333", type: "F", destination: "3333333", quantity: 1)
    end

    it "dose aplicada e estornada no mesmo dia → nada" do
      dose = dose!(applied_at: at(day, 9))
      travel_to(at(day, 9)) { apply!(dose, at: at(day, 9)) }
      travel_to(at(day, 16)) { reverse!(dose) }

      expect(exits).to eq(exits: [], reversals: [])
    end

    it "estorno de saída já ligada → Reversal (a Task 11 decide delete ou late_reversal)" do
      dose = dose!(applied_at: at(day - 1, 9))
      original = travel_to(at(day - 1, 9)) { apply!(dose, at: at(day - 1, 9)) }
      link = bnafar_link!(original)
      reversal = travel_to(at(day, 10)) { reverse!(dose) }

      expect(exits(day - 1)[:exits]).to eq([])
      result = exits(day)
      expect(result[:exits]).to eq([])
      expect(result[:reversals]).to eq([ Bnafar::Exits::Reversal.new(movement: reversal, original_link: link) ])
    end

    it "estorno de saída nunca ligada (anterior ao envio) não vira nada: a fotografia corrige" do
      dose = dose!(applied_at: at(day - 1, 9))
      travel_to(at(day - 1, 9)) { apply!(dose, at: at(day - 1, 9)) }
      travel_to(at(day, 10)) { reverse!(dose) }

      expect(exits).to eq(exits: [], reversals: [])
    end

    it "perda de vacina com loss_code expired → S-VV; sem o código → S-PE" do
      cold = cold_chain_central!.tap { |location| location.update_columns(cnes: "2222222") }
      vial = travel_to(at(day - 1, 8)) { vaccine_lot!(cold, code: "15", doses: 40) }
      expired, broken = travel_to(at(day, 10)) do
        [ bnafar_loss!(cold, vial, 10, loss_code: "expired"), bnafar_loss!(cold, vial, 10) ]
      end

      rows = exits[:exits].index_by(&:movement)
      expect([ rows.fetch(expired).exit_type, rows.fetch(broken).exit_type ]).to eq(%w[S-VV S-PE])
      expect(rows.values.map(&:quantity)).to eq([ 1, 1 ])
    end
  end
end
