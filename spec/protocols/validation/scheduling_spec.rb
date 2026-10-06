require "rails_helper"

# ADR 0029 (spec §5.1): o `when` do agendamento aceita outcome.*, profile.* e
# os passos do próprio protocolo; nada de citizen.*.
RSpec.describe Protocols::Validation::Scheduling do
  def definition(scheduling)
    { "name" => "saude-do-idoso", "version" => 1, "start_step_id" => "quedas",
      "steps" => [ { "id" => "quedas", "prompt" => "?", "answer_type" => "boolean" },
                   { "id" => "remedios", "prompt" => "?", "answer_type" => "integer" } ],
      "scheduling" => scheduling }
  end

  def rule(node) = { "when" => node, "appointment_type" => "consulta_medica", "priority" => "routine", "due_in_days" => 30 }

  it "aceita resultado, perfil e passos" do
    node = { "any" => [ { "gte" => ["outcome.score", 3] }, { "eq" => ["profile.sex", "female"] },
                        { "gte" => ["profile.age", 60] }, { "eq" => ["quedas", "true"] }, { "gte" => ["remedios", 5] } ] }
    expect(described_class.call(definition([ rule(node) ]))).to eq([])
  end

  it "recusa variável de outro lugar, passo inexistente e regra que não é objeto" do
    errors = described_class.call(definition([ rule({ "eq" => ["citizen.neighborhood_id", SecureRandom.uuid] }),
                                               rule({ "eq" => ["fantasma", "1"] }), "x" ]))
    expect(errors.size).to be >= 3
    expect(errors).to all(start_with("scheduling["))
    expect(errors.join).to include("scheduling[0].when", "scheduling[1].when", "scheduling[2] must be an object")
  end

  it "sem scheduling não há erro; scheduling que não é lista é erro; total para lixo" do
    expect(described_class.call(definition(nil).except("scheduling"))).to eq([])
    expect(described_class.call(definition("x"))).to eq(["scheduling must be an array"])
    expect(described_class.call(nil)).to eq([])
  end
end
