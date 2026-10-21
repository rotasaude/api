require "rails_helper"

# Contrato §2 com §13 E17: fechada, linhas do último arquivo (BPA-C
# agregado); aberta, itens faturáveis pela crítica recalculada como em
# /pending (BPA-C ainda não agregado), contagem por motivo e pendências.
RSpec.describe Billing::Summary do
  before do
    billing_city!
    billing_settings!
  end

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:nurse) { nurse!(unit) }
  let(:patient) { billing_patient! }

  def consolidated! = recorded_procedure!(unit: unit, professional: nurse, patient: patient, sigtap_code: "0301100012", cid10: nil)

  it "aberta: crítica recalculada, BPA-C por item, motivos e pendências sem not_bpa" do
    individual = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    2.times { consolidated! }
    recorded_procedure!(unit: unit, professional: doctor, patient: patient, cid10: nil)
    apac = recorded_procedure!(unit: unit, professional: doctor, patient: patient, sigtap_code: "0604320124", cid10: nil)
    expect(apac.instrument).to eq("not_bpa")
    expect(described_class.call(individual.billing_period)).to eq(
      bpa_i_lines: 1, bpa_c_lines: 2, pending: 1, not_billable: ([ "cid_required" ] + apac.blocking_reasons).tally
    )
  end

  # §13 E17: o resumo da competência aberta vem do mesmo recálculo de /pending.
  it "aberta: bate com as pendências (raça/endereço só no fechamento; CNES corrigido depois deixa de contar)" do
    bare = billing_patient!(demographics: false)
    procedure = recorded_procedure!(unit: unit, professional: doctor, patient: bare)
    expect(procedure).to have_attributes(billable: true, blocking_reasons: [])
    period = procedure.billing_period
    summary = described_class.call(period)
    expect(summary).to eq(bpa_i_lines: 0, bpa_c_lines: 0, pending: 1, not_billable: { "missing_race_color" => 1, "missing_address" => 1 })
    expect(summary[:pending]).to eq(Billing::Pending.call(period).size)

    unit.update!(cnes: nil)
    other = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    expect(other.blocking_reasons).to eq(%w[missing_establishment_cnes])
    unit.update!(cnes: billing_cnes)
    summary = described_class.call(period)
    expect(summary).to include(bpa_i_lines: 1, pending: 1)
    expect(summary[:pending]).to eq(Billing::Pending.call(period).size)
  end

  it "fechada: linhas do último arquivo (BPA-C agregado)" do
    individual = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    2.times { consolidated! }
    recorded_procedure!(unit: unit, professional: doctor, patient: patient, cid10: nil)
    period = individual.billing_period
    export = Billing::Close.call(period: period, by: billing_clerk!).payload[:export]
    expect(export).to have_attributes(lines_bpa_i: 1, lines_bpa_c: 1)
    expect(described_class.call(period.reload)).to eq(bpa_i_lines: 1, bpa_c_lines: 1, pending: 1, not_billable: { "cid_required" => 1 })
  end
end
