require "rails_helper"

# F-05.10: as colunas schema/linter/gates do painel Protocolos refletem o portão
# de publicação (Protocols::Gate, F-03.9) rodado sobre a definição de cada
# versão — antes eram a constante "ok", inclusive para rascunho reprovado.
RSpec.describe Admin::ProtocolsQuery do
  def step(id)
    { "id" => id, "prompt" => "?", "answer_type" => "boolean",
      "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } }
  end

  def definition(name, steps: [ step("s1") ])
    { "name" => name, "version" => 1, "start_step_id" => "s1", "steps" => steps,
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 1 } } }
  end

  def draft!(name, definition)
    ProtocolDefinition.create!(name: name, version: 1, status: "draft", definition: definition)
  end

  def row(name)
    described_class.index[:list].find { |r| r[:name] == name }
  end

  it "reports ok on every column for a definition that passes the publish gate" do
    draft!("resp-ok", definition("resp-ok"))

    expect(row("resp-ok")).to include(schema: "ok", linter: "ok", gates: "ok")
  end

  it "reports a linter failure for a draft the gate would refuse" do
    draft!("resp-lint", definition("resp-lint", steps: [ step("s1"), step("s2") ]))

    expect(row("resp-lint")).to include(schema: "ok", linter: "fail", gates: "fail")
  end

  it "reports a schema failure and skips the linter, as the gate does" do
    draft!("x", definition("x"))

    expect(row("x")).to include(schema: "fail", linter: "skipped", gates: "fail")
  end

  it "carries the same columns on each version of the detail view" do
    draft!("resp-lint", definition("resp-lint", steps: [ step("s1"), step("s2") ]))

    version = described_class.show(id: "resp-lint")[:versions].first
    expect(version).to include(schema: "ok", linter: "fail", gates: "fail")
  end
end
