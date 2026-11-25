require "rails_helper"

# Módulo 27b, Task 14 (contrato §5; Q10, Q24; R22): o desfazer da importação
# aplicada. Bloqueado (`revert_blocked`, com os locais) por movimento num local
# da importação criado depois do `applied_at` (fora os da própria importação)
# ou por qualquer `bnafar_records` desses locais criado depois do
# `applied_at`, enviado ou não. Grava `opening_reversal` por movimento de
# abertura, marca `stock_openings.reverted_at` e libera a reabertura.
RSpec.describe OpeningImports::Revert, type: :model do
  let(:header_line) { OpeningImports::Reader::HEADER.join(";") }
  let(:domains) { [ Stock::Domain::MEDICATION, Stock::Domain::IMMUNOBIOLOGICAL, Stock::Domain::VECTOR_CONTROL ] }

  before { pharmacy_city! }

  let!(:central) { central_location!.tap { |location| location.update!(cnes: "2384299") } }
  let(:unit) { create_unit("UBS Centro", cnes: "7654321") }
  let!(:farmacia) { unit_location!(unit) }
  let(:admin) { pharmacy_admin! }
  let(:csv) do
    expires = (Time.zone.today + 200).iso8601
    [ header_line,
      [ "2384299", "medicamento", losartana.catmat_code, "", "RV-1", expires, "20", "1,00", bnafar_cnpj, "1234567890123", "AFB" ].join(";"),
      [ "7654321", "medicamento", amoxicilina.catmat_code, "", "RV-2", expires, "8", "", "", "", "" ].join(";") ].join("\n") + "\n"
  end

  def applied!
    import = OpeningImports::Upload.call(bytes: csv, by: admin, now: Time.current, usable_domains: domains, required_domains: []).payload.fetch(:import)
    result = OpeningImports::Apply.call(import: import, expected_version: import.version, by: admin, usable_domains: domains, now: Time.current)
    raise "apply: #{result.reason}" if result.failure?

    import.reload
  end

  def revert!(import, version: import.version) = described_class.call(import: import, expected_version: version, by: admin, now: Time.current)
  def lot(number) = StockLot.find_by!(lot_number: number)

  it "sem movimento novo → saldo zerado por opening_reversal, abertura liberada, reaplicável" do
    import = applied!

    result = revert!(import)

    expect(result).to be_ok
    expect([ balance_of(central, lot("RV-1")), balance_of(farmacia, lot("RV-2")) ]).to eq([ 0, 0 ])
    reversals = StockMovement.where(kind: "opening_reversal").to_a
    expect(reversals.map { |movement| [ movement.stock_lot_id, movement.quantity ] })
      .to contain_exactly([ lot("RV-1").id, -20 ], [ lot("RV-2").id, -8 ])
    expect(reversals.map(&:recorded_by_user_id).uniq).to eq([ admin.id ])
    expect(reversals.map(&:stock_entry_id)).to all(be_in(StockEntry.where(kind: "opening").pluck(:id)))
    expect(StockOpening.active).to be_empty
    expect(import.reload).to have_attributes(status: "reverted", version: 4)
    expect(import.reverted_at).to be_present

    again = applied!
    expect(again.status).to eq("applied")
    expect(balance_of(central, lot("RV-1"))).to eq(20)
  end

  it "com movimento depois no local (perda no lote importado) → revert_blocked com o local" do
    import = applied!
    bnafar_loss!(farmacia, lot("RV-2"), 2)

    result = revert!(import)
    expect([ result.reason, result.details ]).to eq([ :revert_blocked, { path: "id", locations: [ farmacia.id ] } ])
    expect(StockMovement.where(kind: "opening_reversal")).to be_empty
    expect(import.reload.status).to eq("applied")
  end

  it "com entrada de outro item no local depois → revert_blocked; a de antes do apply não bloqueia" do
    stocked_lot!(central, item: catalog_item(267_778))
    import = applied!
    expect(revert!(import)).to be_ok

    other = applied!
    stocked_lot!(farmacia, item: catalog_item(267_778))
    expect(revert!(other).details[:locations]).to eq([ farmacia.id ])
  end

  it "com registro BNAFAR enviado do local → revert_blocked" do
    import = applied!
    bnafar_record!(bnafar_submission!(status: "finished"), location: central, status: "accepted", sent_at: Time.current)

    expect(revert!(import).details).to eq(path: "id", locations: [ central.id ])
  end

  it "remessa montada e ainda queued → revert_blocked (R22)" do
    import = applied!
    bnafar_record!(bnafar_submission!(status: "queued"), location: farmacia, sent_at: nil)

    expect(revert!(import).details[:locations]).to eq([ farmacia.id ])
  end

  it "aplicação retomada: registro BNAFAR criado entre a queda e a retomada bloqueia (R22, applied_at na primeira entrada)" do
    import = OpeningImports::Upload.call(bytes: csv, by: admin, now: Time.current, usable_domains: domains, required_domains: []).payload.fetch(:import)
    allow(OpeningImports::Apply).to receive(:finish).and_raise("caiu no fim")
    expect { OpeningImports::Apply.call(import: import, expected_version: 2, by: admin, usable_domains: domains, now: Time.current) }
      .to raise_error(RuntimeError)
    bnafar_record!(bnafar_submission!(status: "queued"), location: central, sent_at: nil)
    allow(OpeningImports::Apply).to receive(:finish).and_call_original
    expect(OpeningImports::Apply.call(import: import, expected_version: 2, by: admin, usable_domains: domains, now: Time.current)).to be_ok

    expect(revert!(import.reload).details).to eq(path: "id", locations: [ central.id ])
  end

  it "versão diferente, ou importação que não está aplicada → opening_import_changed" do
    import = applied!
    expect(revert!(import, version: 2).reason).to eq(:opening_import_changed)
    expect(revert!(import)).to be_ok
    expect(revert!(import.reload).reason).to eq(:opening_import_changed)
  end
end
