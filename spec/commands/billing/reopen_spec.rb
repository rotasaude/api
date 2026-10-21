require "rails_helper"

# Spec §5.5 com B8: reabrir exige motivo (10..500, cifrado) e só a fechada;
# o próximo fechamento é a versão 2; a versão 1 fica intacta no histórico.
RSpec.describe Billing::Reopen do
  before do
    billing_city!
    billing_settings!
  end

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:clerk) { billing_clerk! }

  it "reabre com motivo e o próximo arquivo é a versão 2; a 1 não muda" do
    first = recorded_procedure!(unit: unit, professional: doctor)
    period = first.billing_period
    v1 = Billing::Close.call(period: period, by: clerk).payload[:export]
    sha = v1.sha256
    expect(described_class.call(period: period, reason: "curto", by: clerk).reason).to eq(:reason_required)
    expect(described_class.call(period: period, reason: "x" * 501, by: clerk).reason).to eq(:reason_required)
    result = described_class.call(period: period, reason: "CNS do médico corrigido no CNES", by: clerk)
    expect(result.payload[:period]).to have_attributes(status: "open", version: 1, reopened_reason: "CNS do médico corrigido no CNES",
                                                       reopened_by_user_id: clerk.id)
    expect(described_class.call(period: period, reason: "De novo, por engano", by: clerk).reason).to eq(:invalid_transition)
    expect(DomainEvent.where(name: "billing_period.reopened").last.payload).to eq("billing_period_id" => period.id, "version" => 1)
    second = recorded_procedure!(unit: unit, professional: doctor)
    expect(second.billing_period_id).to eq(period.id)
    v2 = Billing::Close.call(period: period.reload, by: clerk).payload[:export]
    expect(v2).to have_attributes(version: 2, lines_bpa_i: 2)
    expect(v1.reload.sha256).to eq(sha)
    expect([ first, second ].map { |p| p.reload.billing_export_id }.uniq).to eq([ v2.id ])
    expect(period.reload).to have_attributes(status: "closed", version: 2)
  end

  # Ruling do controlador (fix round 1): billing_export_id = "entrou no arquivo
  # VIGENTE da competência". O que saiu do faturável no novo fechamento perde a
  # ligação com a versão anterior (senão parece exportado e o cancelamento
  # responderia already_exported).
  it "re-fechamento: o que deixou de ser faturável perde a ligação com a versão anterior" do
    dropped_patient = billing_patient!
    dropped = recorded_procedure!(unit: unit, professional: doctor, patient: dropped_patient)
    kept = recorded_procedure!(unit: unit, professional: doctor)
    period = dropped.billing_period
    v1 = Billing::Close.call(period: period, by: clerk).payload[:export]
    sha = v1.sha256
    expect(dropped.reload.billing_export_id).to eq(v1.id)
    Billing::Reopen.call(period: period, reason: "Raça/cor do paciente estava errada", by: clerk)
    dropped_patient.update!(race_color: nil)
    v2 = Billing::Close.call(period: period.reload, by: clerk).payload[:export]
    expect(v2).to have_attributes(version: 2, lines_bpa_i: 1)
    expect(dropped.reload).to have_attributes(billing_export_id: nil, billable: false, blocking_reasons: %w[missing_race_color])
    expect(kept.reload.billing_export_id).to eq(v2.id)
    expect(v1.reload).to have_attributes(sha256: sha, lines_bpa_i: 2, version: 1)
    expect(Billing::Pending.call(period).map { |item| item[:procedure_id] }).to eq([ dropped.id ])
    expect(Billing::Summary.call(period.reload)).to include(pending: 1, bpa_i_lines: 1)
    expect(Billing::Cancel.call(procedure: dropped, reason: "Lançado em duplicidade", by: clerk)).to be_ok
  end
end
