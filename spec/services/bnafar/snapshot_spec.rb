require "rails_helper"

# Módulo 27b, Task 10 (Valor 6; Review Focus 1): a fotografia de estoque do dia
# R. O saldo soma os movimentos CRIADOS antes do corte (o `recorded_at` pode ser
# retroativo); em trânsito, zerado e domínio desligado ficam fora; a vacina vai
# em frascos.
RSpec.describe Bnafar::Snapshot, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  before { pharmacy_city! }
  let(:med) { Stock::Domain::MEDICATION }
  let(:vaccine) { Stock::Domain::IMMUNOBIOLOGICAL }
  let(:day) { Time.zone.today - 2 }
  let(:central) { central_location!.tap { |location| location.update_columns(cnes: "1234567") } }

  def at(date, hour) = date.in_time_zone.change(hour: hour)
  def cutoff(date) = (date + 1).in_time_zone
  def snapshot(date = day, domains: [ med ], cutoff: cutoff(date)) = described_class.call(reference_on: date, domains: domains, cutoff: cutoff)
  def quantities(rows) = rows.to_h { |row| [ [ row.location.id, row.lot.id ], row.quantity ] }

  it "lote com 30 em R e saída de 10 criada em R+1 (recorded_at em R) → 30 em R, 20 em R+1" do
    lot = travel_to(at(day, 10)) { stocked_lot!(central, item: losartana, quantity: "30") }
    travel_to(at(day + 1, 9)) { bnafar_loss!(central, lot, 10, at: at(day, 15)) }

    expect(quantities(snapshot(day))).to eq({ [ central.id, lot.id ] => 30 })
    expect(quantities(snapshot(day + 1))).to eq({ [ central.id, lot.id ] => 20 })
  end

  it "a linha leva o CNES, o tipo DM01, o item e o rótulo" do
    lot = travel_to(at(day, 10)) { stocked_lot!(central, item: losartana, quantity: "30") }
    row = snapshot.sole

    expect(row).to have_attributes(location: central, cnes: "1234567", type: "A", item_key: "medication:#{losartana.id}",
                                   item_label: losartana.label, lot: lot, quantity: 30)
  end

  it "em trânsito fica fora: sai do central no envio e só entra na unidade no recebimento" do
    unit = unit_location!(create_unit("UBS Trânsito", cnes: "7654321"))
    lot = travel_to(at(day, 8)) { stocked_lot!(central, item: losartana, quantity: "30") }
    transfer = travel_to(at(day, 10)) do
      Pharmacy::SendTransfer.call(from: central, to: unit, items: [ { "lot_id" => lot.id, "quantity" => "10" } ], by: pharmacy_admin!)
                            .payload.fetch(:transfer)
    end
    travel_to(at(day + 1, 9)) do
      result = Pharmacy::ReceiveTransfer.call(transfer: transfer, items: [ { "lot_id" => lot.id, "quantity_received" => "10" } ],
                                              by: pharmacy_admin!)
      raise result.inspect if result.failure?
    end

    expect(quantities(snapshot(day))).to eq({ [ central.id, lot.id ] => 20 })
    expect(quantities(snapshot(day + 1))).to eq({ [ central.id, lot.id ] => 20, [ unit.id, lot.id ] => 10 })
  end

  it "saldo zerado fica fora" do
    lot = travel_to(at(day, 8)) { stocked_lot!(central, item: losartana, quantity: "10") }
    travel_to(at(day, 9)) { bnafar_loss!(central, lot, 10) }

    expect(snapshot).to eq([])
  end

  it "vacina sem bnafar_vaccines fica fora; com ele, conta em frascos (e fração vira nil)" do
    cold = cold_chain_central!.tap { |location| location.update_columns(cnes: "2222222") }
    whole, broken = travel_to(at(day, 8)) { [ vaccine_lot!(cold, code: "15", doses: 30), vaccine_lot!(cold, code: "15", doses: 25) ] }

    expect(snapshot(domains: [ med ])).to eq([])
    rows = snapshot(domains: [ med, vaccine ])
    expect(quantities(rows)).to eq({ [ cold.id, whole.id ] => 3, [ cold.id, broken.id ] => nil })
    expect(rows.map(&:item_key).uniq).to eq([ "immunobiological:15" ])
    expect(rows.map(&:type).uniq).to eq([ "A" ])
  end

  # Revisão final: um imunobiológico cujo código saiu do YAML não derruba a
  # cidade (Units.factor nil → quantidade nil; a pendência é das Pendencies).
  it "vacina com código fora do YAML: quantidade nil e o resto da posição da cidade continua" do
    cold = cold_chain_central!.tap { |location| location.update_columns(cnes: "2222222") }
    med_lot, gone = travel_to(at(day, 8)) { [ stocked_lot!(central, item: losartana, quantity: "10"), vaccine_lot!(cold, code: "ZZ99", doses: 30) ] }

    rows = snapshot(domains: [ med, vaccine ])
    expect(quantities(rows)).to eq({ [ central.id, med_lot.id ] => 10, [ cold.id, gone.id ] => nil })
  end

  it "farmácia e sala da mesma UBS no mesmo CNES, itens separados" do
    unit = create_unit("UBS Dupla", cnes: "7654321")
    pharmacy = unit_location!(unit)
    room = vaccine_room!(unit)
    medication, vaccine_lot = travel_to(at(day, 8)) do
      [ stocked_lot!(pharmacy, item: losartana, quantity: "12"), vaccine_lot!(room, code: "42", doses: 4) ]
    end

    rows = snapshot(domains: [ med, vaccine ])
    expect(rows.map { |row| [ row.cnes, row.type, row.item_key, row.lot, row.quantity ] })
      .to contain_exactly([ "7654321", "F", "medication:#{losartana.id}", medication, 12 ],
                          [ "7654321", "F", "immunobiological:42", vaccine_lot, 4 ])
    expect(described_class.groups(rows).keys).to contain_exactly([ "7654321", "medication:#{losartana.id}" ],
                                                                 [ "7654321", "immunobiological:42" ])
  end

  it "local sem CNES entra com cnes nil (a pendência é das Pendencies)" do
    central.update_columns(cnes: nil)
    travel_to(at(day, 8)) { stocked_lot!(central, item: losartana, quantity: "5") }

    expect(snapshot.sole.cnes).to be_nil
  end
end
