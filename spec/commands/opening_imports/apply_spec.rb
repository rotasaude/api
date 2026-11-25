require "rails_helper"

# Módulo 27b, Task 14 (contrato §5; Q11; R7, R9; Review Focus 5): o envio e a
# aplicação da planilha conferida. A entrada `opening` é de quem aplicou (Q11),
# em até 100 linhas por entrada sem partir os lotes de um item, uma transação
# por local. Nada mexe no estoque antes do apply.
RSpec.describe OpeningImports::Apply, type: :model do
  let(:header_line) { OpeningImports::Reader::HEADER.join(";") }
  let(:domains) { [ Stock::Domain::MEDICATION, Stock::Domain::IMMUNOBIOLOGICAL, Stock::Domain::VECTOR_CONTROL ] }

  before { pharmacy_city! }

  let!(:central) { central_location!.tap { |location| location.update!(cnes: "2384299") } }
  let(:unit) { create_unit("UBS Centro", cnes: "7654321") }
  let!(:farmacia) { unit_location!(unit) }
  let(:uploader) { pharmacy_staff!(central, "stock_keeper") }
  let(:applier) { pharmacy_admin! }
  let(:paracetamol) { catalog_item(267_778) }
  let(:expires) { (Time.zone.today + 200).iso8601 }

  def line(cnes:, item:, lot:, quantity: "10", type: "medicamento", code: item&.catmat_code, price: "1,50", cnpj: bnafar_cnpj, program: "AFB")
    [ cnes, type, code, "", lot, expires, quantity, price, cnpj, "1234567890123", program ].join(";")
  end

  def upload!(lines, by: uploader)
    result = OpeningImports::Upload.call(bytes: ([ header_line ] + lines).join("\n") + "\n", by: by, now: Time.current,
                                         usable_domains: domains, required_domains: [])
    raise "upload: #{result.reason}" if result.failure?

    result.payload.fetch(:import)
  end

  def apply!(import, version: import.version, by: applier, usable: domains)
    described_class.call(import: import, expected_version: version, by: by, usable_domains: usable, now: Time.current)
  end

  it "250 linhas em dois locais → três entradas opening de quem aplicou, saldo certo, file_data NULL" do
    lines = [ losartana, amoxicilina, paracetamol ].flat_map { |item| (1..50).map { |n| line(cnes: "2384299", item: item, lot: "C#{item.catmat_code}-#{n}") } }
    lines += [ losartana, amoxicilina ].flat_map { |item| (1..50).map { |n| line(cnes: "7654321", item: item, lot: "U#{item.catmat_code}-#{n}", quantity: "4") } }
    import = upload!(lines)
    expect(import).to have_attributes(status: "validated", rows_total: 250, rows_valid: 250, version: 2)

    result = apply!(import)

    expect(result).to be_ok
    entries = StockEntry.where(kind: "opening").to_a
    expect(entries.size).to eq(3)
    expect(entries.map(&:recorded_by_user_id).uniq).to eq([ applier.id ])
    expect(entries.map { |entry| entry.movements.count }).to contain_exactly(100, 50, 100)
    expect(entries.group_by(&:stock_location_id).transform_values(&:size)).to eq(central.id => 2, farmacia.id => 1)
    # Os 50 lotes de um item ficam na mesma entrada (sem partir o item).
    expect(StockMovement.where(kind: "opening").group(:catalog_item_id, :stock_location_id).distinct.count(:stock_entry_id).values.uniq).to eq([ 1 ])
    lot = StockLot.find_by!(catalog_item_id: losartana.id, lot_number: "U#{losartana.catmat_code}-7")
    expect(balance_of(farmacia, lot)).to eq(4)
    expect(lot).to have_attributes(unit_price_cents: 150, manufacturer_cnpj: bnafar_cnpj, anvisa_registration: "1234567890123", health_program: "AFB")
    expect(import.reload).to have_attributes(status: "applied", file_data: nil, applied_by_user_id: applier.id, rows_valid: 250, version: 3)
    expect(import.applied_at).to be_present
    expect(OpeningImportRow.where(opening_import_id: import.id, stock_entry_id: nil).count).to eq(0)
  end

  it "item que ganhou abertura entre a conferência e a aplicação → linha opening_exists, o resto entra" do
    import = upload!([ line(cnes: "2384299", item: losartana, lot: "A-1"), line(cnes: "2384299", item: amoxicilina, lot: "A-2") ])
    stocked_lot!(central, item: losartana)

    expect(apply!(import)).to be_ok
    rows = OpeningImportRow.where(opening_import_id: import.id).order(:line)
    expect(rows.map { |row| [ row.status, row.error_codes, row.stock_entry_id.present? ] })
      .to eq([ [ "error", [ "opening_exists" ], false ], [ "valid", [], true ] ])
    expect(import.reload.rows_valid).to eq(1)
    expect(import.report["errors_by_code"]).to eq("opening_exists" => 1)
    expect(StockLot.where(lot_number: "A-2")).to exist
  end

  it "nada mexe no estoque antes do apply" do
    counts = -> { [ StockEntry.count, StockMovement.count, StockLot.count, StockOpening.count ] }
    before = counts.call
    upload!([ line(cnes: "2384299", item: losartana, lot: "N-1") ])
    expect(counts.call).to eq(before)
  end

  it "vacina: 3 frascos de 10 → 30 doses, com o package e a manufacturer_key (R7, R8)" do
    product = Vaccination::Immunobiologicals.find("15")
    patched = product.with(manufacturers: product.manufacturers.map { |m| m.key == "fiocruz" ? m.with(cnpj: bnafar_cnpj) : m })
    allow(Vaccination::Immunobiologicals).to receive(:find).and_call_original
    allow(Vaccination::Immunobiologicals).to receive(:find).with("15").and_return(patched)
    cold = cold_chain_central!.tap { |location| location.update!(cnes: "3333333") }
    import = upload!([ line(cnes: "3333333", item: nil, type: "vacina", code: "15", lot: "VAC-1", quantity: "3", program: "IMUN") ])

    expect(apply!(import)).to be_ok
    lot = StockLot.find_by!(immunobiological_code: "15", lot_number: "VAC-1")
    expect(lot).to have_attributes(manufacturer_key: "fiocruz", manufacturer_cnpj: nil)
    expect(balance_of(cold, lot)).to eq(30)
    expect(StockMovement.find_by!(stock_lot_id: lot.id)).to have_attributes(package_units: 10, packages: 3)
  end

  it "versão diferente ou importação já aplicada → opening_import_changed, nada gravado" do
    import = upload!([ line(cnes: "2384299", item: losartana, lot: "V-1") ])

    expect(apply!(import, version: 1).reason).to eq(:opening_import_changed)
    expect(StockEntry.count).to eq(0)
    expect(apply!(import)).to be_ok
    expect(apply!(import.reload, version: 2).reason).to eq(:opening_import_changed)
    expect(apply!(import).reason).to eq(:opening_import_changed)
    expect(StockEntry.where(kind: "opening").count).to eq(1)
  end

  it "domínio desligado entre a conferência e a aplicação → linhas domain_disabled, nada gravado no local" do
    import = upload!([ line(cnes: "2384299", item: losartana, lot: "D-1"), line(cnes: "7654321", item: amoxicilina, lot: "D-2") ])

    expect(apply!(import, usable: [ Stock::Domain::IMMUNOBIOLOGICAL ])).to be_ok
    rows = OpeningImportRow.where(opening_import_id: import.id).order(:line)
    expect(rows.map { |row| [ row.status, row.error_codes ] }).to eq([ [ "error", [ "domain_disabled" ] ], [ "error", [ "domain_disabled" ] ] ])
    expect(StockEntry.count).to eq(0)
    expect(import.reload).to have_attributes(status: "applied", rows_valid: 0)
  end

  it "applied_at é a primeira entrada da importação, também na aplicação retomada (R22)" do
    import = upload!([ line(cnes: "2384299", item: losartana, lot: "T-1") ])
    allow(described_class).to receive(:finish).and_raise("caiu no fim")
    expect { apply!(import) }.to raise_error(RuntimeError, "caiu no fim")
    first = StockEntry.find_by!(kind: "opening").created_at

    allow(described_class).to receive(:finish).and_call_original
    expect(apply!(import)).to be_ok
    expect(import.reload.applied_at).to eq(first)
  end

  it "o upload grava a importação validada, com o arquivo cifrado e o relatório" do
    import = upload!([ line(cnes: "2384299", item: losartana, lot: "R-1"), line(cnes: "9999999", item: losartana, lot: "R-2") ])
    expect(import).to have_attributes(status: "validated", rows_total: 2, rows_valid: 1, uploaded_by_user_id: uploader.id)
    expect(import.file_data).to start_with(header_line)
    expect(import.file_sha256).to match(/\A\h{64}\z/)
    expect(OpeningImport.connection.select_value("SELECT file_data FROM opening_imports WHERE id = #{OpeningImport.connection.quote(import.id)}"))
      .not_to include("R-1")
    expect(import.report).to include("rows_valid" => 1, "rows_error" => 1, "errors_by_code" => { "cnes_unknown" => 1 })
    expect(import.report["totals_by_location"]).to eq([ { "stock_location_id" => central.id, "rows" => 1, "quantity" => "10.00", "value_cents" => 1500 } ])
  end
end
