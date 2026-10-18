require "rails_helper"

# ADR 0038 (Invariantes): referências, valores, códigos de barras, regras,
# exceções, rodadas do CEQ, lotes e movimentos de estoque nunca mudam nem
# somem; a corrida só piora; o lote de controle só encerra; o bloqueio só
# ganha ação corretiva e fecha uma vez, com ação; a revisão decide uma vez;
# o lote em uso só termina; saldo nunca negativo; justificativa cifrada.
RSpec.describe "Banco da qualidade e dos insumos do laboratório" do
  before { qc_city!(inventory: true) }

  let!(:s) { qc_scenario! }
  let(:staff) { lab_staff! }

  def run!(status: "open") = LabQcRun.create!(lab_instrument: s.instrument, sector: "biochemistry", status: status, started_at: Time.current,
                                evaluated_at: (status == "open" ? nil : Time.current))

  def value!(run) = LabQcValue.create!(lab_qc_run: run, lab_qc_lot: s.lot, level: "Nível 1", analyte_key: "glicose", value: 101, source: "typed",
                                       z_score: BigDecimal("0.2"), lab_qc_target: LabQcTarget.first, rules_fired: [], outcome: "ok",
                                       entered_by_user: staff, entered_at: Time.current)

  it "referência, valor, código de barras e regra são só acréscimo" do
    target = LabQcTarget.first
    expect { target.update!(mean: 1) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { target.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    value = value!(run!)
    expect { value.update!(value: 1) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { s.lot.barcodes.first.update!(barcode: "OUTRO123") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    rule = LabQcRule.create!(lab_instrument: s.instrument, analyte_key: "glicose", rules: LabQcRule::RULES.index_with(true),
                             changed_by_user: staff, created_at: Time.current)
    expect { rule.update!(justification: "x") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "corrida só piora; lote de controle só encerra" do
    run = run!
    run.update!(status: "warning", evaluated_at: Time.current)
    expect { run.update!(status: "approved") }.to raise_error(ActiveRecord::StatementInvalid, /status warning -> approved refused/)
    expect { run.reload.update!(started_at: 1.day.ago) }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
    run.reload.update!(status: "rejected")
    expect { run.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { s.lot.update!(lot_number: "X") }.to raise_error(ActiveRecord::StatementInvalid, /lab_qc_lots/)
    s.lot.reload.update!(status: "closed", closed_on: Date.current)
    expect { s.lot.update!(status: "in_use", closed_on: nil) }.to raise_error(ActiveRecord::StatementInvalid, /lab_qc_lots/)
  end

  it "bloqueio: uma ação corretiva, fecha uma vez e só com ação; um ativo por aparelho e analito" do
    run = run!(status: "rejected")
    block = LabQcBlock.create!(lab_instrument: s.instrument, analyte_key: "glicose", opened_by_run: run, opened_at: Time.current)
    expect { LabQcBlock.create!(lab_instrument: s.instrument, analyte_key: "glicose", opened_by_run: run, opened_at: Time.current) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    closer = run!
    expect { block.update!(closed_by_run: closer, closed_at: Time.current) }.to raise_error(ActiveRecord::StatementInvalid, /lab_qc_blocks/)
    block.reload.update!(corrective_action: "Calibração refeita", corrective_action_by_user: staff, corrective_action_at: Time.current)
    expect { block.update!(corrective_action: "Outra") }.to raise_error(ActiveRecord::StatementInvalid, /lab_qc_blocks/)
    block.reload.update!(closed_by_run: closer, closed_at: Time.current)
    expect { block.update!(closed_at: Time.current + 1) }.to raise_error(ActiveRecord::StatementInvalid, /lab_qc_blocks/)
    expect { block.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "código de barras de controle nunca só 10 dígitos e único na cidade" do
    expect { LabQcLotBarcode.create!(lab_qc_lot: s.lot, level: "Nível 3", barcode: "0000012301", created_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_lab_qc_lot_barcodes_barcode/)
    expect { LabQcLotBarcode.create!(lab_qc_lot: s.lot, level: "Nível 3", barcode: s.lot.barcodes.first.barcode, created_at: Time.current) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "estoque: lote e movimento só acréscimo; saldo nunca negativo; lote em uso só termina" do
    supply = LabSupply.create!(exam_provider: s.provider, name: "Glicose GOD-PAP", kind: "reagent", unit: "kit", tests_per_package: 500,
                               minimum_stock: 2, expiry_alert_days: 30, lab_exam_ids: [ s.exam.id ])
    lot = LabSupplyLot.create!(lab_supply: supply, lot_number: "GL1", expires_on: Date.current + 200, supplier: "Fornecedor", origin: "purchase",
                               created_by_user: staff, created_at: Time.current)
    LabSupplyMovement.create!(lab_supply_lot: lot, kind: "receipt", quantity: 1, recorded_by_user: staff, recorded_at: Time.current, created_at: Time.current)
    expect { LabSupplyMovement.create!(lab_supply_lot: lot, kind: "opening", quantity: -2, recorded_by_user: staff, recorded_at: Time.current, created_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /negative balance/)
    expect { LabSupplyMovement.create!(lab_supply_lot: lot, kind: "opening", quantity: 1, recorded_by_user: staff, recorded_at: Time.current, created_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_lab_supply_movements_sign/)
    expect { lot.update!(supplier: "Outro") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { LabSupplyMovement.first.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    use = LabSupplyInUse.create!(lab_supply_lot: lot, lab_instrument: s.instrument, lab_exam: s.exam, started_at: Time.current, started_by_user: staff)
    expect(LabSupplyInUse.current_lot_id(instrument_id: s.instrument.id, lab_exam_id: s.exam.id)).to eq(lot.id)
    expect(LabSupplyInUse.current_lot_id(instrument_id: nil, lab_exam_id: s.exam.id)).to be_nil
    use.update!(ended_at: Time.current, ended_by_user: staff)
    expect { use.update!(ended_at: nil) }.to raise_error(ActiveRecord::StatementInvalid, /lab_supply_in_use/)
    expect(LabSupplyInUse.current_lot_id(instrument_id: s.instrument.id, lab_exam_id: s.exam.id)).to be_nil
  end

  it "revisão decide uma vez; exceção cifrada e só acréscimo" do
    run = run!(status: "rejected")
    block = LabQcBlock.create!(lab_instrument: s.instrument, analyte_key: "glicose", opened_by_run: run, opened_at: Time.current)
    req = lab_requisition_row!(provider: s.provider, version: s.exam.current_version)
    item = req.items.first
    review = LabQcReviewItem.create!(lab_qc_block: block, lab_requisition_item: item)
    review.update!(decision: "kept", decided_by_user: staff, decided_at: Time.current, note: "Valor coerente")
    expect { review.update!(decision: "rectify") }.to raise_error(ActiveRecord::StatementInvalid, /lab_qc_review_items/)
    exception = LabQcException.create!(lab_qc_block: block, lab_requisition_item: item, justification: "Urgência obstétrica",
                                       granted_by_user: staff, granted_at: Time.current)
    raw = LabQcException.connection.select_value("SELECT justification FROM lab_qc_exceptions WHERE id = #{LabQcException.connection.quote(exception.id)}")
    expect(raw).not_to include("Urgência")
    expect { exception.update!(granted_at: Time.current + 1) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end
end
