require "rails_helper"

# ADR 0036 (spec §5; contrato §1): prestador × exame → catálogo → plataforma;
# urgente = metade arredondada para cima; prazo em dias corridos no fuso da cidade.
RSpec.describe Exams::Deadlines do
  before { exam_city! }

  let(:item) { exam_catalog_item!(result_days: 20, collect_days: nil) }
  let(:provider) { exam_provider! }

  it "resolve na ordem prestador → catálogo → plataforma, e urgente usa a metade para cima" do
    ExamProviderItem.find_or_initialize_by(exam_provider: provider, exam_catalog_item: item).update!(result_days: 7)
    args = { sigtap_code: item.sigtap_code, provider_id: provider.id }
    expect(described_class.days(stage: "result", **args, priority: "routine")).to eq(7)
    expect(described_class.days(stage: "result", **args, priority: "urgent")).to eq(4)
    expect(described_class.days(stage: "result", sigtap_code: item.sigtap_code, provider_id: nil, priority: "routine")).to eq(20)
    expect(described_class.days(stage: "collect", **args, priority: "routine")).to eq(30)
    expect(described_class.days(stage: "authorize", **args, priority: "urgent")).to eq(8)
    expect(described_class.days(stage: "acknowledge", sigtap_code: "0202020380", provider_id: nil, priority: "routine")).to eq(15)
    expect { described_class.days(stage: "bogus", **args, priority: "routine") }.to raise_error(ArgumentError)
  end

  it "conta no fuso da cidade: aberta às 23h59 de São Paulo vence no dia certo (Review Focus 5)" do
    order = Struct.new(:sigtap_code, :priority, :exam_provider_id).new(item.sigtap_code, "routine", nil)
    opened = Time.find_zone("America/Sao_Paulo").local(2026, 10, 13, 23, 59)
    Time.use_zone("America/Sao_Paulo") do
      expect(described_class.due_on(stage: "acknowledge", order: order, opened_at: opened.utc)).to eq(Date.new(2026, 10, 28))
    end
  end
end
