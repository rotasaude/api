require "rails_helper"

# Módulo 27a, Task 6 (ADR 0045; plano do api, Desvio 6; F-27.3; emendas H5/H8/
# H12): transferência do central para a unidade, em dois passos. Enviar tira do
# central (um transfer_out por lote) e deixa "em trânsito" (itens sent); receber
# credita o ENVIADO no destino (transfer_in) e, havendo diferença, baixa a
# diferença como loss com o motivo. Todas as recusas voltam de uma vez, inclusive
# as apuradas sob trava.
RSpec.describe "Transferência do central para a unidade" do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let!(:farmacia) { unit_location! }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:receiver) { pharmacy_staff!(farmacia, "pharmacy_assistant") }
  let(:paracetamol) { catalog_item(267_778) }
  let(:now) { Time.zone.local(2026, 10, 29, 10, 0) }
  let(:later) { now + 2.hours }
  let!(:lot) { stocked_lot!(central, item: paracetamol, quantity: "120", lot_number: "TR-A") }

  def send!(items, to: farmacia, from: central, at: now)
    Pharmacy::SendTransfer.call(from: from, to: to, items: items, by: keeper, now: at)
  end

  def sent!(*lines, at: now)
    result = send!(lines.map { |l, q| { "lot_id" => l.id, "quantity" => q } }, at: at)
    raise result.inspect if result.failure?

    result.payload.fetch(:transfer)
  end

  def receive!(transfer, items, at: later)
    Pharmacy::ReceiveTransfer.call(transfer: transfer, items: items, by: receiver, now: at)
  end

  def got(lot_record, quantity, reason = nil)
    { "lot_id" => lot_record.id, "quantity_received" => quantity }.merge(reason ? { "reason" => reason } : {})
  end

  def line(lot_record = lot, quantity = "100") = { "lot_id" => lot_record.id, "quantity" => quantity }

  def problems_of(result) = result.details[:problems]
  def refusal(error, path) = [ error, path, [ { path: path, error: error.to_s } ] ]
  def refused(result) = [ result.reason, result.details[:path], result.details[:problems] ]

  def written = [ StockTransfer.count, StockTransferItem.count, StockMovement.count ]

  let(:reason) { "Duas caixas chegaram molhadas e foram descartadas" }

  describe "enviar" do
    it "100 de um lote com 120 no central: central 20, transferência sent com o item enviado, destino sem saldo" do
      result = send!([ line ])
      expect(result).to be_ok
      transfer = result.payload.fetch(:transfer)
      expect(transfer).to have_attributes(status: "sent", from_location_id: central.id, to_location_id: farmacia.id, sent_by_user_id: keeper.id,
                                          sent_at: now, received_at: nil, received_by_user_id: nil)
      item = transfer.items.sole
      expect(item).to have_attributes(stock_lot_id: lot.id, quantity_sent: 100, quantity_received: nil)
      movement = StockMovement.where(stock_transfer_id: transfer.id).sole
      expect(movement).to have_attributes(kind: "transfer_out", quantity: -100, stock_location_id: central.id, stock_lot_id: lot.id, recorded_at: now)
      expect(Pharmacy::Ledger.balance(location_id: central.id, lot_id: lot.id)).to eq(20)
      expect(Pharmacy::Ledger.balance(location_id: farmacia.id, lot_id: lot.id)).to eq(0)
    end

    it "vários lotes: um transfer_out por lote e um item por lote" do
      other = stocked_lot!(central, item: paracetamol, quantity: "50", lot_number: "TR-B")
      transfer = sent!([ lot, "10" ], [ other, "50" ])
      expect(transfer.items.pluck(:stock_lot_id, :quantity_sent)).to match_array([ [ lot.id, 10 ], [ other.id, 50 ] ])
      expect(StockMovement.where(stock_transfer_id: transfer.id).pluck(:kind, :quantity)).to match_array([ [ "transfer_out", -10 ], [ "transfer_out", -50 ] ])
      expect(Pharmacy::Ledger.balance(location_id: central.id, lot_id: other.id)).to eq(0)
    end

    it "publica stock_transfer.sent só com os ids" do
      transfer = sent!([ lot, "5" ])
      expect(DomainEvent.where(name: "stock_transfer.sent").sole.payload).to eq("stock_transfer_id" => transfer.id, "user_id" => keeper.id)
    end

    it "enviar mais que o saldo → insufficient_balance com o path da linha, e nada gravado" do
      before = written
      result = send!([ line(lot, "121") ])
      expect(refused(result)).to eq(refusal(:insufficient_balance, "items[0].quantity"))
      expect(written).to eq(before)
      expect(DomainEvent.where(name: "stock_transfer.sent")).to be_empty
    end

    it "duas linhas sem saldo: as duas recusas sob trava voltam juntas, na ordem das linhas" do
      other = stocked_lot!(central, item: paracetamol, quantity: "5", lot_number: "TR-B")
      before = written
      result = send!([ line(lot, "121"), line(other, "6") ])
      expect(refused(result)).to eq([ :insufficient_balance, "items[0].quantity",
                                      [ { path: "items[0].quantity", error: "insufficient_balance" }, { path: "items[1].quantity", error: "insufficient_balance" } ] ])
      expect(written).to eq(before)
    end

    it "uma linha com saldo e outra sem: só a sem saldo é recusada, e a que cabia também não grava" do
      other = stocked_lot!(central, item: paracetamol, quantity: "5", lot_number: "TR-B")
      before = written
      result = send!([ line(lot, "10"), line(other, "6") ])
      expect(refused(result)).to eq(refusal(:insufficient_balance, "items[1].quantity"))
      expect(written).to eq(before)
    end

    it "linha inválida junto de linha sem saldo: ambas voltam de uma vez (a de saldo lida sem trava)" do
      other = stocked_lot!(central, item: paracetamol, quantity: "5", lot_number: "TR-B")
      result = send!([ line(lot, "1,5"), line(other, "6") ])
      expect(refused(result)).to eq([ :invalid_quantity, "items[0].quantity",
                                      [ { path: "items[0].quantity", error: "invalid_quantity" }, { path: "items[1].quantity", error: "insufficient_balance" } ] ])
    end

    it "duas linhas inválidas de tipos diferentes voltam juntas (lote inexistente e quantidade com 3 casas)" do
      result = send!([ line(lot, "0.001"), { "lot_id" => SecureRandom.uuid, "quantity" => "1" } ])
      expect(refused(result)).to eq([ :invalid_quantity, "items[0].quantity",
                                      [ { path: "items[0].quantity", error: "invalid_quantity" }, { path: "items[1].lot_id", error: "invalid_items" } ] ])
      expect(written).to eq([ 0, 0, 1 ])
    end

    it "lote repetido → invalid_items na segunda linha; lote com cara de lixo → invalid_items" do
      result = send!([ line(lot, "10"), line(lot, "10"), { "lot_id" => "nao-e-uuid", "quantity" => "1" } ])
      expect(problems_of(result)).to eq([ { path: "items[1].lot_id", error: "invalid_items" }, { path: "items[2].lot_id", error: "invalid_items" } ])
      expect(result.reason).to eq(:invalid_items)
    end

    it "quantidade fora do papel (número JSON, vírgula, zero, negativa, mais de 99999,99, ausente) → invalid_quantity com o path" do
      [ 1.5, "1,5", "0", "-2", "100000", nil ].each do |bad|
        expect(refused(send!([ { "lot_id" => lot.id, "quantity" => bad } ]))).to eq(refusal(:invalid_quantity, "items[0].quantity"))
      end
      expect(written).to eq([ 0, 0, 1 ])
    end

    it "lista vazia, com mais de 100 itens ou que não é lista → invalid_request path items, sem problems; linha que não é objeto → path da linha" do
      [ [], nil, "x", Array.new(101) { line } ].each do |bad|
        result = send!(bad)
        expect([ result.reason, result.details ]).to eq([ :invalid_request, { path: "items" } ])
      end
      expect(refused(send!([ "x" ]))).to eq(refusal(:invalid_request, "items[0]"))
    end

    it "origem que não é o central → invalid_request path from; destino que não é unidade → path to_location_id junto das linhas inválidas" do
      expect(refused(send!([ line ], from: farmacia, to: central)).first(2)).to eq([ :invalid_request, "from" ])
      expect(refused(send!([ line ], to: central))).to eq(refusal(:invalid_request, "to_location_id"))
      result = send!([ line(lot, "x") ], to: central)
      expect(problems_of(result)).to eq([ { path: "to_location_id", error: "invalid_request" }, { path: "items[0].quantity", error: "invalid_quantity" } ])
    end

    it "destino ou origem inativos → location_inactive (409 no controlador), nada gravado" do
      farmacia.update_columns(active: false)
      result = send!([ line ])
      expect([ result.reason, result.details ]).to eq([ :location_inactive, { path: "to_location_id" } ])
      farmacia.update_columns(active: true)
      central.update_columns(active: false)
      expect(send!([ line ]).reason).to eq(:location_inactive)
      expect(written).to eq([ 0, 0, 1 ])
    end

    it "destino que foi desativado depois de lido (objeto velho): a trava relê e recusa" do
      stale = StockLocation.find(farmacia.id)
      farmacia.update_columns(active: false)
      result = send!([ line ], to: stale)
      expect([ result.reason, result.details ]).to eq([ :location_inactive, { path: "to_location_id" } ])
      expect(written).to eq([ 0, 0, 1 ])
    end
  end

  describe "receber" do
    let!(:transfer) { sent!([ lot, "100" ]) }

    it "receber 100 → received, destino 100, o recebido no item, quem e quando" do
      result = receive!(transfer, [ got(lot, "100") ])
      expect(result).to be_ok
      expect(transfer.reload).to have_attributes(status: "received", received_by_user_id: receiver.id, received_at: later)
      expect(transfer.items.sole).to have_attributes(quantity_received: 100, difference_reason: nil)
      expect(StockMovement.where(stock_location_id: farmacia.id).pluck(:kind, :quantity)).to eq([ [ "transfer_in", 100 ] ])
      expect(Pharmacy::Ledger.balance(location_id: farmacia.id, lot_id: lot.id)).to eq(100)
      expect(Pharmacy::Ledger.balance(location_id: central.id, lot_id: lot.id)).to eq(20)
    end

    it "receber 95 com motivo → received_with_difference; destino 95; extrato [transfer_in 100, loss -5] com o motivo no loss" do
      result = receive!(transfer, [ got(lot, "95", reason) ])
      expect(result).to be_ok
      expect(transfer.reload.status).to eq("received_with_difference")
      expect(transfer.items.sole).to have_attributes(quantity_received: 95, difference_reason: reason)
      statement = StockMovement.where(stock_location_id: farmacia.id, stock_lot_id: lot.id).order(quantity: :desc).pluck(:kind, :quantity)
      expect(statement).to eq([ [ "transfer_in", 100 ], [ "loss", -5 ] ])
      loss = StockMovement.find_by!(kind: "loss", stock_location_id: farmacia.id)
      expect(loss).to have_attributes(reason: reason, stock_transfer_id: transfer.id, recorded_by_user_id: receiver.id, recorded_at: later)
      expect(Pharmacy::Ledger.balance(location_id: farmacia.id, lot_id: lot.id)).to eq(95)
    end

    it "recebido zero com motivo: transfer_in de 100 e loss de 100, destino 0" do
      expect(receive!(transfer, [ got(lot, "0", reason) ])).to be_ok
      expect(transfer.reload.status).to eq("received_with_difference")
      expect(Pharmacy::Ledger.balance(location_id: farmacia.id, lot_id: lot.id)).to eq(0)
      expect(StockMovement.where(stock_location_id: farmacia.id).pluck(:kind, :quantity)).to match_array([ [ "transfer_in", 100 ], [ "loss", -100 ] ])
    end

    it "o motivo é aparado, e sobra (sem diferença) não é gravado" do
      expect(receive!(transfer, [ got(lot, "100", "  Tudo certo, conferido na entrega  ") ])).to be_ok
      expect(transfer.reload.items.sole.difference_reason).to be_nil
      expect(transfer.status).to eq("received")
    end

    it "95 sem motivo, com motivo curto, longo ou que não é texto → reason_required com o path; nada gravado" do
      before = written
      [ nil, "curto", "x" * 501, 12_345_678_901 ].each do |bad|
        item = got(lot, "95").merge("reason" => bad)
        expect(refused(receive!(transfer, [ item ]))).to eq(refusal(:reason_required, "items[0].reason"))
      end
      expect(written).to eq(before)
      expect(transfer.reload.status).to eq("sent")
    end

    it "motivo com 10 e com 500 caracteres vale" do
      expect(receive!(transfer, [ got(lot, "99", "x" * 10) ])).to be_ok
      other = sent!([ stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TR-B"), "10" ])
      expect(receive!(other, [ got(other.items.first.stock_lot, "9", "y" * 500) ])).to be_ok
    end

    it "mais que o enviado, vírgula, negativo, número JSON ou ausente → invalid_quantity com o path" do
      [ "101", "95,5", "-1", 95, nil, "0.001" ].each do |bad|
        expect(refused(receive!(transfer, [ { "lot_id" => lot.id, "quantity_received" => bad } ]))).to eq(refusal(:invalid_quantity, "items[0].quantity_received"))
      end
      expect(transfer.reload.status).to eq("sent")
    end

    it "faltando um lote → invalid_items com path items; lote alheio ou repetido → invalid_items na linha" do
      other = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TR-B")
      two = sent!([ lot, "10" ], [ other, "10" ])
      expect(refused(receive!(two, [ got(lot, "10") ]))).to eq(refusal(:invalid_items, "items"))
      stranger = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TR-C")
      result = receive!(two, [ got(lot, "10"), got(other, "10"), got(stranger, "10"), got(lot, "10") ])
      expect(problems_of(result)).to eq([ { path: "items[2].lot_id", error: "invalid_items" }, { path: "items[3].lot_id", error: "invalid_items" } ])
      expect(two.reload.status).to eq("sent")
    end

    it "todas as recusas de uma vez: quantidade inválida, motivo faltando e lote faltando" do
      other = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TR-B")
      third = stocked_lot!(central, item: paracetamol, quantity: "10", lot_number: "TR-C")
      three = sent!([ lot, "10" ], [ other, "10" ], [ third, "10" ])
      result = receive!(three, [ got(lot, "11"), got(other, "5") ])
      expect(result.reason).to eq(:invalid_quantity)
      expect(problems_of(result)).to eq([ { path: "items[0].quantity_received", error: "invalid_quantity" },
                                          { path: "items[1].reason", error: "reason_required" },
                                          { path: "items", error: "invalid_items" } ])
    end

    it "lista vazia, grande demais ou que não é lista → invalid_request path items; linha que não é objeto → path da linha" do
      [ [], nil, "x", Array.new(101) { got(lot, "1") } ].each do |bad|
        result = receive!(transfer, bad)
        expect([ result.reason, result.details ]).to eq([ :invalid_request, { path: "items" } ])
      end
      expect(problems_of(receive!(transfer, [ "x" ]))).to eq([ { path: "items[0]", error: "invalid_request" }, { path: "items", error: "invalid_items" } ])
    end

    it "receber de novo → already_received, nada novo gravado; vale também para o objeto velho (a trava relê o status)" do
      stale = StockTransfer.find(transfer.id)
      expect(receive!(transfer, [ got(lot, "100") ])).to be_ok
      before = written
      again = receive!(stale, [ got(lot, "100") ])
      expect([ again.reason, again.details ]).to eq([ :already_received, {} ])
      expect(receive!(transfer.reload, [ got(lot, "100") ]).reason).to eq(:already_received)
      expect(written).to eq(before)
      expect(Pharmacy::Ledger.balance(location_id: farmacia.id, lot_id: lot.id)).to eq(100)
    end

    it "destino desativado à força → location_inactive, nada gravado" do
      farmacia.update_columns(active: false)
      before = written
      result = receive!(transfer, [ got(lot, "100") ])
      expect(result.reason).to eq(:location_inactive)
      expect(written).to eq(before)
      expect(transfer.reload.status).to eq("sent")
    end

    it "saldo que não fecha sob trava (defesa do livro) → insufficient_balance no path do recebido, e a transferência continua sent" do
      allow(Pharmacy::Ledger).to receive(:record!).and_wrap_original do |original, **args|
        raise Pharmacy::Ledger::Insufficient, args.fetch(:lot).id if args[:kind] == "loss"

        original.call(**args)
      end
      before = written
      result = receive!(transfer, [ got(lot, "95", reason) ])
      expect(refused(result)).to eq(refusal(:insufficient_balance, "items[0].quantity_received"))
      expect(written).to eq(before)
      expect(transfer.reload.status).to eq("sent")
      expect(transfer.items.sole.quantity_received).to be_nil
    end

    it "publica stock_transfer.received com os ids e o booleano da diferença" do
      expect(receive!(transfer, [ got(lot, "95", reason) ])).to be_ok
      other = sent!([ lot, "10" ])
      expect(receive!(other, [ got(lot, "10") ])).to be_ok
      payloads = DomainEvent.where(name: "stock_transfer.received").order(:occurred_at, :id).map(&:payload)
      expect(payloads).to contain_exactly(
        { "stock_transfer_id" => transfer.id, "user_id" => receiver.id, "with_difference" => true },
        { "stock_transfer_id" => other.id, "user_id" => receiver.id, "with_difference" => false }
      )
      expect(payloads.to_json).not_to include(reason)
    end

    it "a linha validada do comando também não deixa o motivo sair em inspect/to_s/pretty_print/as_json" do
      row = Pharmacy::ReceiveTransfer::Row.new(index: 0, item: nil, received: 1, difference: 1, reason: reason)
      expect([ row.inspect, row.to_s, row.pretty_inspect, row.as_json.to_json ].join).not_to include(reason)
    end

    it "o motivo não aparece em inspect/to_s/as_json do item nem do movimento" do
      expect(receive!(transfer, [ got(lot, "95", reason) ])).to be_ok
      [ transfer.items.sole, StockMovement.find_by!(kind: "loss") ].each do |record|
        expect([ record.inspect, record.to_s, record.as_json.to_json ].join).not_to include(reason)
      end
    end
  end

  describe "ciclo completo com dois lotes" do
    it "envia dois lotes, recebe um inteiro e um com diferença, e os saldos fecham" do
      other = stocked_lot!(central, item: paracetamol, quantity: "60", lot_number: "TR-B")
      transfer = sent!([ lot, "100" ], [ other, "60" ])
      expect(receive!(transfer, [ got(lot, "100"), got(other, "58", reason) ])).to be_ok
      expect(transfer.reload.status).to eq("received_with_difference")
      expect(Pharmacy::Ledger.balances(location_id: farmacia.id, lot_ids: [ lot.id, other.id ])).to eq(lot.id => 100, other.id => 58)
      expect(Pharmacy::Ledger.balances(location_id: central.id, lot_ids: [ lot.id, other.id ])).to eq(lot.id => 20, other.id => 0)
    end
  end
end
