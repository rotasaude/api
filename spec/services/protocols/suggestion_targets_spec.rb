require "rails_helper"

# ADR 0027 (spec 2026-10-05 §4.3): sugestão para protocolo que não existe hoje
# na cidade é aviso, não erro — a cidade pode criar o sugerido depois.
RSpec.describe Protocols::SuggestionTargets do
  before { create_default_protocol! }
  after { Rails.cache.clear }

  def definition(*names)
    { "name" => "saude-mental", "suggestions" => names.map { |n| { "protocol" => n, "when" => { "eq" => ["q1", "true"] } } } }
  end

  it "avisa só os nomes sem nenhuma versão na cidade, uma vez cada" do
    expect(described_class.warnings(definition(StartTriage::DEFAULT_PROTOCOL_NAME, "fantasma", "fantasma")))
      .to eq(["suggestion protocol 'fantasma' does not exist in this city"])
  end

  it "não avisa sem sugestões e é total" do
    expect(described_class.warnings(definition)).to eq([])
    [ nil, "x", { "suggestions" => "x" }, { "suggestions" => [ nil, "x", {} ] } ].each do |input|
      expect(described_class.warnings(input)).to eq([]), input.inspect
    end
  end
end
