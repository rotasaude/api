require "rails_helper"

# Módulo 27a, Task 5 (ADR 0045; plano do api, Desvios 1, 4, 5; Review Focus 5;
# emendas H1/H8/H12): nota, doação e inventário de abertura. Embalagem vira
# quantidade; lote por (item, número) com validade e fabricante conferidos; a
# abertura vale uma vez por (local, item); todas as recusas voltam de uma vez.
RSpec.describe Pharmacy::RecordEntry do
  let!(:city) { pharmacy_city! }
  let!(:central) { central_location! }
  let(:keeper) { pharmacy_staff!(central, "stock_keeper") }
  let(:paracetamol) { catalog_item(267_778) }
  let(:today) { Time.zone.today }
  let(:now) { Time.zone.local(2026, 10, 29, 10, 0) }
  let(:document) { { "number" => "NF-1234", "supplier" => "Distribuidora Sul" } }

  def line(item = paracetamol, **over)
    { "catalog_item_id" => item.id, "lot_number" => "LOTE-A1", "expires_on" => (today + 365).iso8601,
      "package" => { "units_per_package" => 30, "packages" => 10 } }.merge(over.transform_keys(&:to_s))
  end

  def entry!(items, kind: "invoice", doc: document, location: central, at: now)
    catalog = Pharmacy::Json.catalog_for(Array(items.is_a?(Array) ? items : []).filter_map { |row| row["catalog_item_id"] if row.is_a?(Hash) })
    described_class.call(location: location, kind: kind, document: doc, items: items, by: keeper, catalog: catalog, now: at)
  end

  def written = [ StockEntry.count, StockLot.count, StockMovement.count, StockOpening.count ]

  describe "nota com embalagem" do
    it "30 por embalagem × 10 embalagens → um movimento receipt de 300 com package_units e packages; o lote guarda a unidade de dispensação" do
      result = entry!([ line(manufacturer: "EMS") ])
      expect(result).to be_ok
      entry = result.payload.fetch(:entry)
      expect(entry).to have_attributes(kind: "invoice", document_number: "NF-1234", supplier: "Distribuidora Sul",
                                       stock_location_id: central.id, recorded_by_user_id: keeper.id)
      movement = result.payload.fetch(:movements).sole
      expect(movement).to have_attributes(kind: "receipt", quantity: 300, package_units: 30, packages: 10,
                                          stock_location_id: central.id, stock_entry_id: entry.id, recorded_at: now)
      lot = movement.stock_lot
      expect(lot).to have_attributes(lot_number: "LOTE-A1", manufacturer: "EMS", dispensing_unit: "comprimido",
                                     catalog_item_id: paracetamol.id, catmat_code: 267_778, created_by_user_id: keeper.id)
      expect(balance_of(central, lot)).to eq(300)
    end

    it "quantity \"300\" com a mesma embalagem passa; \"299\" é invalid_quantity em items[0].quantity e nada é gravado" do
      expect(entry!([ line(quantity: "300") ])).to be_ok

      before = written
      result = entry!([ line(lot_number: "LOTE-B2", quantity: "299") ])
      expect([ result.reason, result.details[:path] ]).to eq([ :invalid_quantity, "items[0].quantity" ])
      expect(written).to eq(before)
    end

    it "sem embalagem, só a quantidade; sem nenhuma das duas é invalid_quantity" do
      expect(entry!([ line(package: nil, quantity: "12.5") ]).payload.fetch(:movements).sole.quantity).to eq(BigDecimal("12.5"))
      expect(entry!([ line(lot_number: "LOTE-C3", package: nil) ]).details).to include(path: "items[0].quantity")
    end

    it "embalagem fora de 1..10000, não inteira ou com produto acima de 99999,99 é invalid_quantity em items[0].package" do
      [ { "units_per_package" => 0, "packages" => 10 }, { "units_per_package" => 30, "packages" => 10_001 },
        { "units_per_package" => "30", "packages" => 10 }, { "units_per_package" => 30.5, "packages" => 10 },
        { "units_per_package" => 10_000, "packages" => 10 }, { "units_per_package" => 10_000, "packages" => 10_000 },
        { "units_per_package" => 30 }, "30x10" ].each do |package|
        before = written
        result = entry!([ line(package: package) ])
        expect([ result.reason, result.details[:path] ]).to eq([ :invalid_quantity, "items[0].package" ]), package.inspect
        expect(written).to eq(before)
      end
    end

    it "o produto até 99999 passa; 100000 (acima de 99999,99) não" do
      expect(entry!([ line(package: { "units_per_package" => 5_000, "packages" => 20 }) ]).reason).to eq(:invalid_quantity)
      expect(entry!([ line(package: { "units_per_package" => 9_999, "packages" => 10 }) ])).to be_ok
      expect(entry!([ line(lot_number: "LOTE-B2", package: { "units_per_package" => 4_999, "packages" => 20 }) ])).to be_ok
    end

    it "quantidade como no papel: vírgula, número JSON, 3 casas, sinal e acima de 99999,99 → invalid_quantity" do
      [ "1,5", 1.5, 1, "0.001", "-2", "100000", "0", "", nil, " 5" ].each do |raw|
        result = entry!([ line(package: nil, quantity: raw) ])
        expect([ result.reason, result.details[:path] ]).to eq([ :invalid_quantity, "items[0].quantity" ]), raw.inspect
      end
    end
  end

  describe "lote" do
    it "o mesmo lote de novo (outra nota) é reaproveitado: um StockLot, dois movimentos" do
      expect(entry!([ line ])).to be_ok
      expect(entry!([ line(package: nil, quantity: "50") ], doc: document.merge("number" => "NF-9999"), at: now + 1.minute)).to be_ok

      expect(StockLot.where(catalog_item_id: paracetamol.id).count).to eq(1)
      lot = StockLot.sole
      expect(StockMovement.where(stock_lot_id: lot.id).order(:recorded_at, :id).pluck(:kind, :quantity)).to eq([ [ "receipt", 300 ], [ "receipt", 50 ] ])
      expect(balance_of(central, lot)).to eq(350)
    end

    it "o mesmo número com outra validade → lot_mismatch em items[0].lot_number, nada gravado" do
      entry!([ line ])
      before = written
      result = entry!([ line(expires_on: (today + 400).iso8601) ])
      expect([ result.reason, result.details[:path] ]).to eq([ :lot_mismatch, "items[0].lot_number" ])
      expect(written).to eq(before)
    end

    it "fabricante informado e diferente (ou informado onde o lote não tem) → lot_mismatch; sem fabricante, vale" do
      entry!([ line(manufacturer: "EMS") ])
      expect(entry!([ line(manufacturer: "Medley") ]).reason).to eq(:lot_mismatch)
      expect(entry!([ line(manufacturer: "EMS", package: nil, quantity: "1") ])).to be_ok
      expect(entry!([ line(package: nil, quantity: "1") ])).to be_ok

      entry!([ line(lot_number: "SEM-FAB") ])
      expect(entry!([ line(lot_number: "SEM-FAB", manufacturer: "EMS") ]).reason).to eq(:lot_mismatch)
    end

    it "duas linhas do mesmo lote na mesma nota com validade diferente → lot_mismatch na segunda" do
      result = entry!([ line, line(expires_on: (today + 99).iso8601) ])
      expect([ result.reason, result.details[:path] ]).to eq([ :lot_mismatch, "items[1].lot_number" ])
      expect(written).to eq([ 0, 0, 0, 0 ])
    end

    it "duas linhas do mesmo lote igual valem: um lote, dois movimentos" do
      result = entry!([ line, line(package: nil, quantity: "5") ])
      expect(result).to be_ok
      expect(StockLot.count).to eq(1)
      expect(result.payload.fetch(:movements).map(&:quantity)).to eq([ 300, 5 ])
    end

    it "a unidade de dispensação sai da forma do item: PARACETAMOL → comprimido; LOSARTANA (sem forma) → unidade" do
      entry!([ line, line(losartana, lot_number: "LOS-1") ])
      expect(StockLot.find_by!(catalog_item_id: paracetamol.id).dispensing_unit).to eq("comprimido")
      expect(StockLot.find_by!(catalog_item_id: losartana.id).dispensing_unit).to eq("unidade")
    end

    it "lote existente mantém a unidade gravada mesmo que a regra mude" do
      entry!([ line ])
      allow(Pharmacy::DispensingUnit).to receive(:for).and_return("frasco")
      entry!([ line(package: nil, quantity: "1") ])
      expect(StockLot.sole.dispensing_unit).to eq("comprimido")
    end
  end

  describe "validade" do
    it "lote vencido → expired_lot em items[0].expires_on" do
      result = entry!([ line(expires_on: (today - 1).iso8601) ])
      expect([ result.reason, result.details[:path] ]).to eq([ :expired_lot, "items[0].expires_on" ])
      expect(written).to eq([ 0, 0, 0, 0 ])
    end

    it "o dia da validade ainda vale: expires_on == hoje passa, ontem não (fronteira no fuso da cidade)" do
      late = Time.zone.local(2026, 10, 29, 23, 50)
      expect(entry!([ line(expires_on: "2026-10-29") ], at: late)).to be_ok
      expect(entry!([ line(lot_number: "LOTE-ONT", expires_on: "2026-10-28") ], at: late).reason).to eq(:expired_lot)
    end

    it "data fora do ISO (ou impossível) é invalid_request em items[0].expires_on" do
      [ "29/10/2027", "2027-02-30", "2027-1-5", 20_271_029, nil, "", "2027-10-29T00:00:00Z" ].each do |raw|
        result = entry!([ line(expires_on: raw) ])
        expect([ result.reason, result.details[:path] ]).to eq([ :invalid_request, "items[0].expires_on" ]), raw.inspect
      end
    end
  end

  describe "documento e itens" do
    it "doação vira movimento donation e a entrada guarda o fornecedor" do
      result = entry!([ line ], kind: "donation", doc: { "number" => "DOA-7", "supplier" => "Hospital Parceiro" })
      expect(result.payload.fetch(:movements).sole.kind).to eq("donation")
      expect(result.payload.fetch(:entry)).to have_attributes(kind: "donation", supplier: "Hospital Parceiro", document_number: "DOA-7")
    end

    it "número fora do padrão e fornecedor vazio ou acima de 120 são recusados com path (e juntos com os itens)" do
      [ [ { "number" => "NF 1", "supplier" => "X" }, "document.number" ], [ { "number" => "NF-1", "supplier" => "" }, "document.supplier" ],
        [ { "number" => "NF-1", "supplier" => "a" * 121 }, "document.supplier" ], [ { "number" => "NF-1" }, "document.supplier" ],
        [ nil, "document" ], [ "NF-1", "document" ] ].each do |doc, path|
        result = entry!([ line ], doc: doc)
        expect([ result.reason, result.details[:path] ]).to eq([ :invalid_request, path ]), doc.inspect
      end
      result = entry!([ line(lot_number: "X Y") ], doc: { "number" => "NF 1", "supplier" => "S" })
      expect(result.details[:problems].map { |p| p[:path] }).to eq(%w[document.number items[0].lot_number])
    end

    it "items fora de 1..100 ou fora de lista é invalid_request em items" do
      [ [], nil, "x", { "a" => 1 }, Array.new(101) { |i| line(lot_number: "L#{i}") } ].each do |items|
        result = entry!(items)
        expect([ result.reason, result.details[:path] ]).to eq([ :invalid_request, "items" ]), items.inspect[0, 30]
      end
      expect(entry!(Array.new(100) { |i| line(lot_number: "L#{i}") })).to be_ok
    end

    it "item que não é objeto → invalid_request em items[i]" do
      result = entry!([ "x" ])
      expect([ result.reason, result.details[:path] ]).to eq([ :invalid_request, "items[0]" ])
    end

    it "item inexistente, inativo ou sem id → invalid_item em items[0].catalog_item_id" do
      [ SecureRandom.uuid, nil, 5, "abc" ].each do |id|
        result = entry!([ line(catalog_item_id: id) ])
        expect([ result.reason, result.details[:path] ]).to eq([ :invalid_item, "items[0].catalog_item_id" ]), id.inspect
      end
      paracetamol.update_columns(status: "removed")
      expect(entry!([ line ]).reason).to eq(:invalid_item)
    end

    it "item escondido da busca (hidden) vale: o catálogo esconde da busca, não do estoque" do
      paracetamol.update_columns(hidden: true)
      expect(entry!([ line ])).to be_ok
    end

    it "número do lote fora de LOTE_NUMBER e fabricante acima de 120 → invalid_request com path" do
      [ [ "lot_number", "A B" ], [ "lot_number", "" ], [ "lot_number", "a" * 41 ], [ "lot_number", 12 ], [ "manufacturer", "m" * 121 ], [ "manufacturer", 3 ] ].each do |key, value|
        result = entry!([ line(key => value) ])
        expect([ result.reason, result.details[:path] ]).to eq([ :invalid_request, "items[0].#{key}" ]), [ key, value ].inspect
      end
    end

    it "H8/H12: com dois itens inválidos, todas as recusas voltam de uma vez e nada é gravado" do
      result = entry!([ line(lot_number: "BOM-1"), line(lot_number: "VENC", expires_on: (today - 3).iso8601),
                        line(lot_number: "BOM-2", package: nil, quantity: "1,5"), line(catalog_item_id: SecureRandom.uuid) ])
      expect(result.reason).to eq(:expired_lot)
      expect(result.details[:path]).to eq("items[1].expires_on")
      expect(result.details[:problems]).to eq([ { path: "items[1].expires_on", error: "expired_lot" },
                                                { path: "items[2].quantity", error: "invalid_quantity" },
                                                { path: "items[3].catalog_item_id", error: "invalid_item" } ])
      expect(written).to eq([ 0, 0, 0, 0 ])
    end

    it "um item com vários defeitos soma todos, na ordem dos campos" do
      result = entry!([ { "catalog_item_id" => paracetamol.id, "lot_number" => "!!", "expires_on" => "ontem", "manufacturer" => 1, "quantity" => "x" } ])
      expect(result.details[:problems].map { |p| [ p[:path], p[:error] ] }).to eq(
        [ [ "items[0].lot_number", "invalid_request" ], [ "items[0].expires_on", "invalid_request" ],
          [ "items[0].manufacturer", "invalid_request" ], [ "items[0].quantity", "invalid_quantity" ] ]
      )
    end

    it "kind desconhecido → invalid_request em document.kind" do
      result = entry!([ line ], kind: "gift")
      expect([ result.reason, result.details[:path] ]).to eq([ :invalid_request, "document.kind" ])
    end
  end

  describe "inventário de abertura" do
    it "dois lotes do mesmo item na mesma abertura passam: uma marca de abertura, dois movimentos opening; ignora o documento" do
      result = entry!([ line(lot_number: "AB-1"), line(lot_number: "AB-2", package: nil, quantity: "40") ], kind: "opening", doc: nil)
      expect(result).to be_ok
      entry = result.payload.fetch(:entry)
      expect(entry).to have_attributes(kind: "opening", document_number: nil, supplier: nil)
      expect(StockOpening.where(stock_location_id: central.id, catalog_item_id: paracetamol.id).pluck(:stock_entry_id)).to eq([ entry.id ])
      expect(result.payload.fetch(:movements).map { |m| [ m.kind, m.quantity ] }).to eq([ [ "opening", 300 ], [ "opening", 40 ] ])
    end

    it "uma marca por item distinto; documento dado na abertura é ignorado (mesmo inválido)" do
      result = entry!([ line, line(losartana, lot_number: "LOS-1") ], kind: "opening", doc: { "number" => "!!" })
      expect(result).to be_ok
      expect(StockOpening.where(stock_location_id: central.id).count).to eq(2)
    end

    it "segunda abertura do item no local → opening_exists em items[0].catalog_item_id e nada gravado (nem o lote novo)" do
      entry!([ line ], kind: "opening", doc: nil)
      before = written
      result = entry!([ line(lot_number: "OUTRO-LOTE") ], kind: "opening", doc: nil)
      expect([ result.reason, result.details[:path] ]).to eq([ :opening_exists, "items[0].catalog_item_id" ])
      expect(written).to eq(before)
      expect(StockLot.where(lot_number: "OUTRO-LOTE")).not_to exist
    end

    it "abertura em dois itens, um já aberto e um não: recusa o aberto, grava nada do outro" do
      entry!([ line ], kind: "opening", doc: nil)
      before = written
      result = entry!([ line(losartana, lot_number: "LOS-1"), line(lot_number: "NOVO") ], kind: "opening", doc: nil)
      expect(result.details[:problems]).to eq([ { path: "items[1].catalog_item_id", error: "opening_exists" } ])
      expect(written).to eq(before)
    end

    it "a abertura de um local não impede a de outro, nem uma nota depois da abertura" do
      other = unit_location!
      entry!([ line ], kind: "opening", doc: nil)
      expect(entry!([ line(lot_number: "L-OUTRO") ], kind: "opening", doc: nil, location: other)).to be_ok
      expect(entry!([ line(lot_number: "L-NOTA") ])).to be_ok
    end
  end

  describe "local" do
    it "local desativado → location_inactive e nada gravado" do
      stale = StockLocation.find(central.id)
      central.update!(active: false)
      before = written
      expect(entry!([ line ], location: stale).reason).to eq(:location_inactive)
      expect(written).to eq(before)
    end
  end

  describe "ordem de travas (lotes → local)" do
    it "trava todos os lotes de uma vez, em ordem de id, ANTES do local e de qualquer movimento" do
      calls = []
      allow(Pharmacy::Ledger).to receive(:lock_lots!).and_wrap_original { |m, ids| calls << [ :lots, ids.dup ]; m.call(ids) }
      allow(Pharmacy::Ledger).to receive(:lock_location!).and_wrap_original { |m, id| calls << [ :location, id ]; m.call(id) }
      allow(Pharmacy::Ledger).to receive(:record!).and_wrap_original { |m, **kw| calls << [ :record, kw[:lot].id ]; m.call(**kw) }

      result = entry!([ line(lot_number: "ZZ-9"), line(lot_number: "AA-1"), line(losartana, lot_number: "MM-5") ])
      expect(result).to be_ok
      lot_ids = StockLot.pluck(:id)
      expect(calls.map(&:first)).to eq(%i[lots location record record record])
      expect(calls.first.last).to eq(lot_ids.sort)
      expect(calls.first.last.size).to eq(3)
    end

    it "lotes novos nascem em ordem fixa de (item, número), seja qual for a ordem do pedido" do
      order = []
      allow(StockLot).to receive(:insert_all).and_wrap_original { |m, rows, **kw| order << rows.map { |r| r[:lot_number] }; m.call(rows, **kw) }
      entry!([ line(lot_number: "ZZ-9"), line(lot_number: "AA-1"), line(lot_number: "MM-5") ])
      expect(order.flatten).to eq(%w[AA-1 MM-5 ZZ-9])
    end
  end

  describe "stocked_lot! (auxiliar de teste, pelo comando)" do
    it "abre o item e depois entra por nota; lote já vencido entra com o movimento datado no dia da validade" do
      expired = stocked_lot!(central, item: paracetamol, quantity: "4", lot_number: "VELHO", expires_on: today - 10, by: keeper)
      fresh = stocked_lot!(central, item: paracetamol, quantity: "6", by: keeper)
      expect(StockEntry.order(:created_at).pluck(:kind)).to eq(%w[opening invoice])
      expect(balance_of(central, expired)).to eq(4)
      expect(balance_of(central, fresh)).to eq(6)
      expect(expired.expires_on).to eq(today - 10)
      expect(StockMovement.find_by!(stock_lot_id: expired.id).recorded_at.to_date).to eq(today - 10)
      expect(DomainEvent.where(name: "stock_receipt.recorded").count).to eq(2)
    end
  end

  describe "evento" do
    it "stock_receipt.recorded com exatamente stock_entry_id e user_id" do
      entry = entry!([ line ]).payload.fetch(:entry)
      event = DomainEvent.where(name: "stock_receipt.recorded").sole
      expect(event.payload).to eq("stock_entry_id" => entry.id, "user_id" => keeper.id)
    end

    it "recusa não publica evento" do
      entry!([ line(expires_on: (today - 1).iso8601) ])
      expect(DomainEvent.where(name: "stock_receipt.recorded")).not_to exist
    end
  end
end
