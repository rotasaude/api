require "rails_helper"

# A assinatura vale para o conteúdo EXATO (spec S5). O digest não pode depender
# da ordem em que as chaves foram escritas — o jsonb do Postgres reordena —, e
# tem de mudar com qualquer mudança de conteúdo, inclusive a ordem de uma lista.
RSpec.describe Protocols::ContentDigest do
  let(:definition) do
    { "name" => "dengue", "version" => 1,
      "steps" => [ { "id" => "s1", "prompt" => "?" }, { "id" => "s2", "prompt" => "!" } ] }
  end

  # Task 1: copiado de spec/commands/protocols_lifecycle_spec.rb#definition_hash.
  # A Task 2 troca este `let` pelo helper spec/support/protocol_signatures.rb.
  let(:protocol_definition_hash) do
    {
      "name" => "dengue", "version" => 1, "start_step_id" => "s1",
      "steps" => [
        { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  it "is a hex SHA-256" do
    expect(described_class.call(definition)).to match(/\A\h{64}\z/)
  end

  it "does not depend on key order, at any depth" do
    reordered = { "steps" => [ { "prompt" => "?", "id" => "s1" }, { "prompt" => "!", "id" => "s2" } ],
                  "version" => 1, "name" => "dengue" }

    expect(described_class.call(reordered)).to eq(described_class.call(definition))
  end

  it "treats symbol and string keys alike" do
    expect(described_class.call(definition.deep_symbolize_keys)).to eq(described_class.call(definition))
  end

  it "changes when any value changes" do
    changed = definition.deep_dup.tap { |d| d["steps"][1]["prompt"] = "?!" }

    expect(described_class.call(changed)).not_to eq(described_class.call(definition))
  end

  it "changes when the order of a list changes" do
    swapped = definition.merge("steps" => definition["steps"].reverse)

    expect(described_class.call(swapped)).not_to eq(described_class.call(definition))
  end

  it "answers the same digest for what the database stores and gives back" do
    Current.city = TEST_CITY_A
    stored = ProtocolDefinition.create!(name: "dengue", version: 1, status: "draft",
                                        definition: protocol_definition_hash)

    expect(described_class.call(stored.reload.definition)).to eq(described_class.call(protocol_definition_hash))
  ensure
    Current.reset
  end
end
