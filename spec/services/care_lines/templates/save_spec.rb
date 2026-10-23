require "rails_helper"

RSpec.describe CareLines::Templates::Save do
  def sql(statement) = PlatformRecord.transaction(requires_new: true) { PlatformRecord.connection.execute(statement) }

  def attrs(**over)
    entry = CareLines::Templates::Load.entries.find { |e| e["key"] == "diabetes_c4" }
    entry.slice("key", "name", "indicator", "declared_condition", "eligibility", "practices").merge(over.transform_keys(&:to_s))
  end

  it "grava versões em sequência, nunca altera a anterior, e audita só ids" do
    first = described_class.call(attrs).payload[:template]
    second = described_class.call(attrs(name: "Diabetes (revisão 2027)")).payload[:template]
    expect([ first.version, second.version ]).to eq([ 1, 2 ])
    expect(CareLineTemplate.current("diabetes_c4")).to eq(second)
    expect { sql("UPDATE care_line_templates SET name = 'x' WHERE id = '#{first.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /care_line_templates: immutable/)
    expect { sql("DELETE FROM care_line_templates WHERE id = '#{first.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /care_line_templates: immutable/)
    event = PlatformEvent.where(name: "care_line.template_changed").order(:created_at).last
    expect(event.payload.keys).to match_array(%w[care_line_template_id template_key version])
  end

  it "recusa chave fora do catálogo, indicador trocado, pontos que não somam 100 e nome longo" do
    expect(described_class.call(attrs(key: "asthma_c9")).reason).to eq(:invalid_key)
    expect(described_class.call(attrs(indicator: "C5")).reason).to eq(:invalid_indicator)
    practices = attrs["practices"].map { |p| p.merge("points" => 10) }
    expect(described_class.call(attrs(practices: practices)).details).to eq(field: "practices.points")
    expect(described_class.call(attrs(name: "x" * 121)).reason).to eq(:invalid_name)
    expect(described_class.call(attrs(declared_condition: "none")).reason).to eq(:invalid_declared_condition)
    expect(CareLineTemplate.count).to eq(0)
  end

  it "recusa declared_condition fora de eligibility.declared (como a linha própria); sem condição, grava" do
    entry = CareLines::Templates::Load.entries.find { |e| e["key"] == "diabetes_c4" }
    outside = entry["eligibility"].merge("declared" => [ "hypertension" ])
    result = described_class.call(attrs(eligibility: outside))
    expect([ result.reason, result.details ]).to eq([ :invalid_declared_condition, { field: "declaredCondition" } ])
    expect(described_class.call(attrs(eligibility: entry["eligibility"].except("declared"))).reason).to eq(:invalid_declared_condition)
    expect(CareLineTemplate.count).to eq(0)
    expect(described_class.call(attrs(declared_condition: nil, eligibility: outside))).to be_ok
  end

  it "os templates do catalog-base.yml carregam: a condição de cada um está em eligibility.declared" do
    entries = CareLines::Templates::Load.entries
    expect(entries.size).to eq(6)
    expect(entries.select { |e| e["declared_condition"] }.map { |e| e["eligibility"]["declared"].include?(e["declared_condition"]) }).to all(be(true))
    expect(CareLines::Templates::Load.call).to eq(created: 6)
  end
end
