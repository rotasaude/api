require "rails_helper"

# Módulo 03, critério de fechamento (ADR 0009): bateria de casos clínicos
# conhecidos por protocolo, com o Outcome esperado POR VERSÃO. Linter de grafo
# não prova correção clínica; isto prova que uma versão continua classificando
# como foi aprovada. Versão nova do protocolo = casos novos aqui, revisados por
# quem assina a publicação — nunca editar os casos de uma versão já aprovada.
#
# Protocolo semeado em toda cidade nova: config/city_templates/triage_respiratoria.json.
RSpec.describe "Invariante: regressão clínica por versão (ADR 0009)" do
  cases_by_version = {
    ["triage-respiratoria", 1] => [
      { name: "sem tosse encerra sem perguntar febre",
        answers: { "tosse" => "false" }, tier: "baixa", priority: 9, score: 0 },
      { name: "tosse sem febre alta fica em cuidados em casa",
        answers: { "tosse" => "true", "febre" => "false" }, tier: "baixa", priority: 9, score: 3 },
      { name: "tosse com febre alta é prioridade alta",
        answers: { "tosse" => "true", "febre" => "true" }, tier: "alta", priority: 1, score: 8 }
    ]
  }

  def definition_for(name, version)
    hash = JSON.parse(File.read(Rails.root.join("config/city_templates/#{name.tr('-', '_')}.json")))
    raise "template is v#{hash['version']}, cases are v#{version}" unless hash["version"] == version
    hash
  end

  cases_by_version.each do |(name, version), cases|
    describe "#{name} v#{version}" do
      let(:definition) { definition_for(name, version) }
      let(:protocol) { Protocols::Definitions.build(definition) }

      it "passes the publication gate" do
        expect(Protocols::Gate.call(definition)).to be_valid
      end

      cases.each do |c|
        it c[:name] do
          outcome = protocol.evaluate(c[:answers])
          expect(outcome).to be_terminal
          expect(outcome.to_h.slice(:tier, :priority, :score)).to eq(c.slice(:tier, :priority, :score))
          expect(definition.dig("recommendations", outcome.tier)).to be_present
        end
      end
    end
  end
end
