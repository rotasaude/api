require "rails_helper"

# Módulo 35a, Task 11 (ADR 0054; contrato §8, §11; Q9; W-8): ciclos de UBV do
# bloqueio ativo. Até ubv_cycles_max; duração inclusiva (ends_on − starts_on +
# 1) de ubv_cycle_days_min a _max; starts_on ≥ ends_on anterior +
# ubv_cycle_interval_days. Fora do ativo → invalid_transition path status.
RSpec.describe VectorControl::Blocks::AddCycle, type: :model do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:center) { city_block!(neighborhood: neighborhood, number: "5") }
  let(:start) { Time.zone.today }

  def active_block!
    block = TransmissionBlock.create!(disease_group: "arbovirus", center_block: center)
    expect(VectorControl::Blocks::Confirm.call(block: block, center_block_id: center.id, block_ids: [ center.id ], seen_case_ids: [],
                                                 by: coordinator)).to be_ok
    block.reload
  end

  def add(block, starts_on, ends_on)
    described_class.call(block: block, starts_on: starts_on&.iso8601, ends_on: ends_on&.iso8601, by: coordinator)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "3 ciclos de 3 a 5 dias com intervalo 5 passam; intervalo 4 → starts_on; 6 dias → ends_on; quarto ciclo → cycles" do
    block = active_block!
    expect(add(block, start, start + 2)).to be_ok                        # 3 dias
    expect(refusal(add(block, start + 6, start + 8))).to eq([ :cycle_invalid, { path: "starts_on" } ]) # ends + 4
    expect(refusal(add(block, start + 7, start + 12))).to eq([ :cycle_invalid, { path: "ends_on" } ])  # 6 dias
    expect(refusal(add(block, start + 7, start + 8))).to eq([ :cycle_invalid, { path: "ends_on" } ])   # 2 dias
    expect(add(block, start + 7, start + 11)).to be_ok                   # ends + 5, 5 dias
    third = add(block, start + 16, start + 19)                           # 4 dias
    expect(third).to be_ok
    expect(refusal(add(block, start + 30, start + 32))).to eq([ :cycle_invalid, { path: "cycles" } ])

    expect(block.cycles.order(:number).map { |cycle| [ cycle.number, cycle.starts_on, cycle.ends_on ] })
      .to eq([ [ 1, start, start + 2 ], [ 2, start + 7, start + 11 ], [ 3, start + 16, start + 19 ] ])
    expect(third.payload[:block]).to eq(block)
  end

  it "datas ausentes ou inválidas → invalid_request com o path" do
    block = active_block!
    expect(refusal(add(block, nil, start))).to eq([ :invalid_request, { path: "starts_on" } ])
    expect(refusal(described_class.call(block: block, starts_on: start.iso8601, ends_on: "2026-02-30", by: coordinator)))
      .to eq([ :invalid_request, { path: "ends_on" } ])
    expect(block.cycles).to be_empty
  end

  it "ciclo em bloqueio closed ou proposed → 409 invalid_transition path status" do
    proposed = TransmissionBlock.create!(disease_group: "arbovirus", center_block: center)
    expect(refusal(add(proposed, start, start + 2))).to eq([ :invalid_transition, { path: "status" } ])

    block = active_block!
    expect(VectorControl::Blocks::Close.call(block: block, by: coordinator)).to be_ok
    expect(refusal(add(block.reload, start, start + 2))).to eq([ :invalid_transition, { path: "status" } ])
    expect(TransmissionBlockCycle.count).to eq(0)
  end
end
