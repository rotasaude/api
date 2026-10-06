require "rails_helper"

# Spec §6.5 / contratos §4.3 (+ §8, R18): attention a ≤ 5 dias úteis com
# pendente, recusada ou falha (sending NÃO conta); critical com record e zero
# aceitas a ≤ 3 dias úteis.
RSpec.describe Ledi::Alert do
  def counts(**overrides) = { accepted: 0, rejected: 0, pending: 0, sending: 0, failed: 0 }.merge(overrides)

  it "longe do prazo: none, mesmo com pendência" do
    expect(described_class.level(counts: counts(pending: 4), business_days_left: 6, record_mode: "record")).to eq("none")
  end

  it "a 5 dias úteis com pendente, recusada ou falha: attention" do
    %i[pending rejected failed].each do |key|
      expect(described_class.level(counts: counts(accepted: 1, key => 1), business_days_left: 5,
                                   record_mode: "integrated")).to eq("attention"), key.to_s
    end
    expect(described_class.level(counts: counts(accepted: 3), business_days_left: 5, record_mode: "integrated"))
      .to eq("none")
  end

  # R18: linhas só em sending não pedem atenção.
  it "linhas só em sending não elevam o alerta" do
    expect(described_class.level(counts: counts(accepted: 1, sending: 2), business_days_left: 5,
                                 record_mode: "integrated")).to eq("none")
  end

  it "record e zero aceitas a 3 dias úteis: critical; integrated não" do
    expect(described_class.level(counts: counts, business_days_left: 3, record_mode: "record")).to eq("critical")
    expect(described_class.level(counts: counts(pending: 1), business_days_left: 3, record_mode: "integrated"))
      .to eq("attention")
    expect(described_class.level(counts: counts, business_days_left: 4, record_mode: "record")).to eq("none")
  end

  # Review Focus 4: depois do prazo não há o que alertar.
  it "prazo vencido: none" do
    expect(described_class.level(counts: counts(pending: 9), business_days_left: 0, record_mode: "record")).to eq("none")
  end
end
