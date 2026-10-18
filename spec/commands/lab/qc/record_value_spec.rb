require "rails_helper"

# Spec §5.2–§5.7, Desvios 5–7 e C-E14: corrida do dia aberta no primeiro
# valor; z (3 casas, antes de avaliar) contra a referência vigente; Westgard
# na gravação; 1-2s avisa; a reprovação abre o bloqueio e a próxima corrida é
# nova; a série ignora a corrida reprovada e inclui a de aviso; 4-1s e 10x
# também entre níveis; o bloqueio fecha só com ação corretiva e corrida aceita
# com todos os níveis gravados depois da ação.
RSpec.describe Lab::Qc::RecordValue do
  include ActiveSupport::Testing::TimeHelpers

  before { qc_city! }

  let(:s) { qc_scenario! }
  let(:staff) { lab_staff! }
  let(:lead) { lab_releaser!(s.provider, lead: true) }

  def record(level, z, lot: s.lot, **opts)
    described_class.call(instrument: s.instrument, lot: lot, level: level, analyte_key: "glicose", value: qc_glucose(level, z),
                         source: "typed", by: staff, **opts)
  end

  # Segundo lote do mesmo material, com a mesma bula no aparelho.
  def second_lot!
    lot = qc_lot!(s.material)
    LabQcHelpers::GLUCOSE_QC.each { |level, (mean, sd)| qc_target!(lot, level: level, analyte_key: "glicose", instrument: s.instrument, mean: mean, sd: sd) }
    lot
  end

  def new_run! = Lab::Qc::OpenRun.call(instrument: s.instrument, by: staff).payload[:run]

  it "abre a corrida do dia, calcula z e aprova; o segundo nível entra na mesma corrida" do
    first = record("Nível 1", 0.4).payload
    expect(first[:value]).to have_attributes(z_score: BigDecimal("0.4"), outcome: "ok", rules_fired: [], source: "typed", reagent_lot_id: nil)
    expect(first[:value].lab_qc_target.version).to eq(1)
    expect(first[:run]).to have_attributes(status: "approved", lab_instrument_id: s.instrument.id, sector: "biochemistry")
    expect(first[:run].evaluated_at).to be_present
    expect(first[:block]).to be_nil
    second = record("Nível 2", -0.6).payload
    expect(second[:run].id).to eq(first[:run].id)
    expect(DomainEvent.where(name: "lab_qc_run.evaluated").map(&:payload)).to eq([ { "lab_qc_run_id" => first[:run].id, "status" => "approved" } ])
  end

  it "qc_value! do suporte grava pelo comando; usa a referência vigente (versão mais nova)" do
    qc_target!(s.lot, level: "Nível 1", analyte_key: "glicose", instrument: s.instrument, mean: 110, sd: 5, at: Time.current - 1.day)
    payload = qc_value!(s, "Nível 1", value: BigDecimal("110"))
    expect([ payload[:value].z_score, payload[:value].lab_qc_target.version, payload[:run].status ]).to eq([ BigDecimal("0"), 2, "approved" ])
    expect { qc_value!(s, "Nível 9", value: BigDecimal("100")) }.to raise_error(/invalid_levels/)
  end

  it "z arredondado a 3 casas ANTES de avaliar: 2,0004 grava 2,000 e não dispara 1-2s" do
    value = record("Nível 1", BigDecimal("2.0004")).payload[:value]
    expect([ value.z_score, value.rules_fired, value.outcome ]).to eq([ BigDecimal("2"), [], "ok" ])
    rounded_up = record("Nível 2", BigDecimal("2.0005")).payload[:value]
    expect([ rounded_up.z_score, rounded_up.rules_fired ]).to eq([ BigDecimal("2.001"), [ "1_2s" ] ])
  end

  it "1-2s só avisa: a corrida fica warning" do
    warned = record("Nível 1", 2.2).payload
    expect([ warned[:value].outcome, warned[:value].rules_fired, warned[:run].status ]).to eq([ "warning", [ "1_2s" ], "warning" ])
  end

  it "a série do nível exclui a corrida atual e inclui a corrida de aviso (2-2s entre corridas)" do
    record("Nível 1", 2.2)
    repeat = record("Nível 1", 2.3).payload
    expect([ repeat[:value].rules_fired, repeat[:run].status ]).to eq([ [ "1_2s" ], "warning" ]) # repetição na mesma corrida não é série
    new_run!
    expect(record("Nível 1", 2.4).payload[:value].rules_fired).to eq(%w[1_2s 2_2s])
  end

  it "reprovação: corrida rejected, bloqueio aberto, próxima corrida nova; série sem a reprovada" do
    record("Nível 1", 0.5)
    bad = record("Nível 2", 3.4).payload
    expect(bad[:value].rules_fired).to eq(%w[1_2s 1_3s])
    expect(bad[:run].status).to eq("rejected")
    expect(bad[:block]).to have_attributes(lab_instrument_id: s.instrument.id, analyte_key: "glicose", opened_by_run_id: bad[:run].id, closed_at: nil)
    expect(DomainEvent.where(name: "lab_qc_block.opened").map(&:payload))
      .to eq([ { "lab_qc_block_id" => bad[:block].id, "lab_instrument_id" => s.instrument.id } ])
    refused = record("Nível 1", 0.1, run_id: bad[:run].id)
    expect([ refused.reason, refused.details ]).to eq([ :invalid_transition, { status: "rejected" } ])
    nxt = record("Nível 1", 0.1).payload
    expect(nxt[:run].id).not_to eq(bad[:run].id)
    again = record("Nível 2", 2.3).payload
    expect(again[:value].rules_fired).to eq([ "1_2s" ]) # o 3,4 reprovado não forma 2-2s
    expect(again[:notice]).to eq("corrective_action_required")
    expect(again[:block].reload.closed_at).to be_nil
    expect(LabQcBlock.active.count).to eq(1)
  end

  it "fecha só com ação corretiva e corrida aceita com todos os níveis gravados depois dela" do
    travel_to(Time.zone.now.change(hour: 9)) do
      # Horários distintos: com o relógio parado, duas corridas empatariam em started_at.
      record("Nível 1", 0.2)
      block = record("Nível 2", 3.5, now: Time.current + 1).payload[:block]
      record("Nível 1", 0.3, now: Time.current + 2)
      expect(record("Nível 2", -0.2, now: Time.current + 3).payload[:notice]).to eq("corrective_action_required")
      Lab::Qc::RecordCorrectiveAction.call(block: block, text: "Calibração refeita e reagente trocado", by: staff, now: Time.current + 60)
      after_l1 = record("Nível 1", 0.1, now: Time.current + 120).payload
      expect([ after_l1[:block].reload.closed_at, after_l1[:notice] ]).to eq([ nil, nil ]) # o Nível 2 da corrida é de antes da ação
      closing = record("Nível 2", 0.1, now: Time.current + 180).payload
      expect(closing[:block].reload).to have_attributes(closed_by_run_id: closing[:run].id, closed_by_user_id: staff.id)
      expect(closing[:block].closed_at).to be_present
      expect(DomainEvent.where(name: "lab_qc_block.closed").map { |e| e.payload.keys.sort }).to eq([ %w[lab_instrument_id lab_qc_block_id] ])
    end
  end

  it "C-E14: 4-1s entre níveis (2 níveis × 2 corridas) reprova, mesmo sem série do nível" do
    record("Nível 1", 1.2)
    record("Nível 2", 1.3)
    new_run!
    expect(record("Nível 1", 1.4).payload[:value].rules_fired).to eq([])
    last = record("Nível 2", 1.1).payload
    expect([ last[:value].rules_fired, last[:run].status ]).to eq([ [ "4_1s" ], "rejected" ])
  end

  it "C-E14: 10x entre níveis (2 níveis × 5 corridas); um valor do outro lado não dispara" do
    4.times do
      record("Nível 1", 0.5)
      expect(record("Nível 2", 0.4).payload[:value].rules_fired).to eq([])
      new_run!
    end
    record("Nível 1", 0.5)
    expect(record("Nível 2", 0.4).payload[:value].rules_fired).to eq([ "10x" ])

    other = qc_scenario!
    other_record = lambda do |level, z|
      described_class.call(instrument: other.instrument, lot: other.lot, level: level, analyte_key: "glicose", value: qc_glucose(level, z),
                           source: "typed", by: staff).payload[:value]
    end
    other_record.call("Nível 1", -0.3)
    other_record.call("Nível 2", 0.4)
    Lab::Qc::OpenRun.call(instrument: other.instrument, by: staff)
    4.times do
      other_record.call("Nível 1", 0.5)
      other_record.call("Nível 2", 0.4)
      Lab::Qc::OpenRun.call(instrument: other.instrument, by: staff)
    end
    expect(LabQcValue.where(lab_qc_lot_id: other.lot.id).pluck(:rules_fired).flatten).to eq([])
  end

  it "C-E15: troca de lote reinicia a série entre níveis (4-1s)" do
    record("Nível 1", 1.2)
    record("Nível 2", 1.3)
    new_run!
    other_lot = second_lot!
    record("Nível 1", 1.4, lot: other_lot)
    mixed = record("Nível 2", 1.1, lot: other_lot).payload # misturando lotes, 1,2 1,3 1,4 1,1 seria 4-1s
    expect([ mixed[:value].rules_fired, mixed[:run].status ]).to eq([ [], "approved" ])
    new_run!
    record("Nível 1", 1.5, lot: other_lot)
    expect(record("Nível 2", 1.2, lot: other_lot).payload[:value].rules_fired).to eq([ "4_1s" ]) # mesmo lote ainda dispara
  end

  it "C-E15: troca de lote reinicia a série entre níveis (10x)" do
    4.times do
      record("Nível 1", 0.5)
      record("Nível 2", 0.4)
      new_run!
    end
    other_lot = second_lot!
    record("Nível 1", 0.5, lot: other_lot)
    expect(record("Nível 2", 0.4, lot: other_lot).payload[:value].rules_fired).to eq([]) # misturando lotes seriam dez
    4.times do
      new_run!
      record("Nível 1", 0.5, lot: other_lot)
      record("Nível 2", 0.4, lot: other_lot)
    end
    expect(LabQcValue.where(lab_qc_lot_id: other_lot.id).order(:entered_at, :created_at).last.rules_fired).to eq([ "10x" ])
  end

  it "corrida do dia é a mais recente: depois de uma reprovada abre nova, que fecha o bloqueio após a ação" do
    travel_to(Time.zone.now.change(hour: 9)) do
      r1 = record("Nível 1", 0.1).payload[:run]
      record("Nível 2", 0.2)
      r2 = Lab::Qc::OpenRun.call(instrument: s.instrument, by: staff, now: Time.current + 10).payload[:run]
      bad = record("Nível 1", 3.5, now: Time.current + 20).payload
      expect([ bad[:run].id, bad[:run].status ]).to eq([ r2.id, "rejected" ])
      Lab::Qc::RecordCorrectiveAction.call(block: bad[:block], text: "Calibração refeita", by: staff, now: Time.current + 30)
      first = record("Nível 1", 0.1, now: Time.current + 40).payload
      expect([ r1.id, r2.id ]).not_to include(first[:run].id)
      closing = record("Nível 2", -0.1, now: Time.current + 50).payload
      expect(closing[:run].id).to eq(first[:run].id)
      expect(bad[:block].reload).to have_attributes(closed_by_run_id: first[:run].id)
      expect(LabQcBlock.active.count).to eq(0)
    end
  end

  it "corrida dada (HL7) velha em memória: relida sob a trava, a situação não regride nem dispara evento" do
    run = record("Nível 1", 0.1).payload[:run]
    stale = LabQcRun.find(run.id)
    LabQcRun.find(run.id).update!(status: "rejected", evaluated_at: Time.current)
    events = DomainEvent.where(name: "lab_qc_run.evaluated").count
    payload = record("Nível 2", 0.2, run: stale).payload
    expect([ payload[:run].id, payload[:run].status ]).to eq([ run.id, "rejected" ])
    expect(DomainEvent.where(name: "lab_qc_run.evaluated").count).to eq(events)
    alien = qc_scenario!
    expect(record("Nível 2", 0.2, run: LabQcRun.create!(lab_instrument: alien.instrument, sector: "biochemistry", status: "open",
                                                          started_at: Time.current)).reason).to eq(:not_found)
  end

  it "aparelho desativado depois de carregado: relido sob a trava, recusa" do
    loaded = LabInstrument.find(s.instrument.id)
    LabInstrument.find(s.instrument.id).update!(active: false)
    expect(described_class.call(instrument: loaded, lot: s.lot, level: "Nível 1", analyte_key: "glicose", value: BigDecimal("100"),
                                source: "typed", by: staff).reason).to eq(:invalid_instrument)
  end

  it "C-E14: corrida reprovada não entra na série entre níveis" do
    record("Nível 1", 1.2)
    expect(record("Nível 2", 3.5).payload[:run].status).to eq("rejected")
    record("Nível 1", 1.3)
    record("Nível 2", 1.4)
    new_run!
    expect(record("Nível 1", 1.1).payload[:value].rules_fired).to eq([]) # o 1,2 e o 3,5 reprovados não contam
  end

  it "recusas: nível, analito, aparelho, lote encerrado ou vencido, sem referência" do
    one = BigDecimal("1")
    expect(described_class.call(instrument: s.instrument, lot: s.lot, level: "Nível 9", analyte_key: "glicose", value: one, source: "typed", by: staff).reason)
      .to eq(:invalid_levels)
    expect(described_class.call(instrument: s.instrument, lot: s.lot, level: "Nível 1", analyte_key: "ureia", value: one, source: "typed", by: staff).reason)
      .to eq(:no_target)
    other = qc_instrument!(s.provider, name: "Analisador bioquímico 2", hl7_equipment_id: "BIO-02")
    expect(described_class.call(instrument: other, lot: s.lot, level: "Nível 1", analyte_key: "glicose", value: one, source: "typed", by: staff).reason)
      .to eq(:no_target)
    alien = qc_instrument!(lab_provider!, hl7_equipment_id: "BIO-77")
    expect(described_class.call(instrument: alien, lot: s.lot, level: "Nível 1", analyte_key: "glicose", value: one, source: "typed", by: staff).reason)
      .to eq(:invalid_instrument)
    expired = qc_lot!(s.material, expires_on: Time.zone.today - 1)
    qc_target!(expired, level: "Nível 1", analyte_key: "glicose", instrument: s.instrument, mean: 100, sd: 5)
    expect(described_class.call(instrument: s.instrument, lot: expired, level: "Nível 1", analyte_key: "glicose", value: BigDecimal("100"),
                                source: "typed", by: staff).reason).to eq(:expired_lot)
    expect(described_class.call(instrument: s.instrument, lot: s.lot, level: "Nível 1", analyte_key: "glicose", value: one, source: "typed", by: staff,
                                run_id: SecureRandom.uuid).reason).to eq(:not_found)
    expect { described_class.call(instrument: s.instrument, lot: s.lot, level: "Nível 1", analyte_key: "glicose", value: 1.0, source: "typed", by: staff) }
      .to raise_error(ArgumentError)
    s.lot.update!(status: "closed", closed_on: Time.zone.today)
    expect(record("Nível 1", 0).reason).to eq(:lot_closed)
    expect(LabQcValue.count).to eq(0)
  end

  it "regra desligada pelo RT não reprova; valor nunca vai a evento" do
    Lab::Qc::SaveRules.call(instrument: s.instrument, analyte_key: "glicose", rules: LabQcRule::RULES.index_with(true).merge("1_3s" => false),
                            justification: "Faixa da bula larga demais para este lote", by: lead)
    value = record("Nível 1", 3.5).payload[:value]
    expect([ value.rules_fired, value.outcome ]).to eq([ [ "1_2s" ], "warning" ])
    expect(DomainEvent.where("name LIKE 'lab_qc%'").pluck(:payload).to_json).not_to include(qc_glucose("Nível 1", 3.5).to_s("F"))
  end
end
