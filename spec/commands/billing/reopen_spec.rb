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
end
