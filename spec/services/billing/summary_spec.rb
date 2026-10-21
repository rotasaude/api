require "rails_helper"

# Contrato §2: fechada, linhas do último arquivo (BPA-C agregado); aberta,
# itens faturáveis pela crítica gravada (BPA-C ainda não agregado), contagem
# por motivo e pendências (sem not_bpa nem APS).
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

  it "aberta: crítica gravada, BPA-C por item, motivos e pendências sem not_bpa nem APS" do
    individual = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    2.times { consolidated! }
    recorded_procedure!(unit: unit, professional: doctor, patient: patient, cid10: nil)
    apac = recorded_procedure!(unit: unit, professional: doctor, patient: patient, sigtap_code: "0604320124", cid10: nil)
    raw_procedure!(unit: unit, patient: patient, professional: doctor, billing_period: individual.billing_period,
                   billing_competence: individual.billing_competence, billable: false, blocking_reasons: %w[establishment_is_aps])
    expect(apac.instrument).to eq("not_bpa")
    expect(described_class.call(individual.billing_period)).to eq(
      bpa_i_lines: 1, bpa_c_lines: 2, pending: 1,
      not_billable: ([ "cid_required", "establishment_is_aps" ] + apac.blocking_reasons).tally
    )
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
