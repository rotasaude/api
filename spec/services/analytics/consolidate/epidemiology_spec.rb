# spec/services/analytics/consolidate/epidemiology_spec.rb
require "rails_helper"

# Spec §3.4 (epi.answer) e D5: só perguntas marcadas `analytic` NA VERSÃO da
# triagem, só boolean/enum, só respostas que batem com uma opção declarada.
RSpec.describe Analytics::Consolidate::Epidemiology do
  let(:day) { Time.zone.today - 3 }
  let(:centro) { Neighborhood.create!(name: "Centro", source: "manual") }
  let!(:v1) { analytics_protocol!(version: 1, status: "retired", marks: %w[febre]) }
  let!(:v2) { analytics_protocol!(version: 2, status: "active") } # febre, sintoma e idade (integer) marcadas

  def run!(from = day, to = day) = described_class.call(from: from, to: to, at: Time.current)

  def rows
    AnalyticsDailyFact.where(metric: "epi.answer")
                      .pluck(:day, :neighborhood_id, :protocol_name, :protocol_version, :question_id, :dim, :value)
  end

  it "conta respostas marcadas de boolean e enum por bairro, protocolo, versão, pergunta e opção" do
    a_triage!(day: day, protocol: v2, neighborhood: centro,
              answers: { "febre" => "true", "sintoma" => "Manchas", "gestante" => "true", "idade" => "34" })
    a_triage!(day: day, protocol: v2, neighborhood: centro,
              answers: { "febre" => "true", "sintoma" => "Nenhum", "gestante" => "false", "idade" => "51" })
    a_triage!(day: day, protocol: v2, answers: { "febre" => "false", "sintoma" => "Manchas" })

    run!

    expect(rows).to contain_exactly(
      [ day, centro.id, v2.name, 2, "febre", "true", 2 ],
      [ day, centro.id, v2.name, 2, "sintoma", "Manchas", 1 ],
      [ day, centro.id, v2.name, 2, "sintoma", "Nenhum", 1 ],
      [ day, nil, v2.name, 2, "febre", "false", 1 ],
      [ day, nil, v2.name, 2, "sintoma", "Manchas", 1 ]
    )
  end

  it "a marca é da versão da triagem: na v1 só febre conta" do
    a_triage!(day: day, protocol: v1, answers: { "febre" => "true", "sintoma" => "Manchas" })

    run!

    expect(rows).to contain_exactly([ day, nil, v1.name, 1, "febre", "true", 1 ])
  end

  it "ignora pergunta sem marca, integer marcado à mão, resposta fora das opções e resposta em formato estranho" do
    a_triage!(day: day, protocol: v2,
              answers: { "febre" => "sim", "sintoma" => "Febre alta", "gestante" => "true", "idade" => "34" })

    run!

    expect(rows).to be_empty
  end

  it "boolean gravado como JSON true conta como \"true\"" do
    a_triage!(day: day, protocol: v2, answers: { "febre" => true })

    run!

    expect(rows).to contain_exactly([ day, nil, v2.name, 2, "febre", "true", 1 ])
  end

  # Definição gravada direto no banco, sem schema: uma linha malformada não
  # pode derrubar a transação da cidade inteira (as quatro frentes).
  it "definição com steps que não é array é ignorada, sem abortar a consolidação" do
    # Em rascunho o guarda do banco deixa trocar o conteúdo; o consolidador
    # não olha o status, só a versão da triagem.
    broken = analytics_protocol!(name: "quebrado", status: "draft")
    broken.update_columns(definition: broken.definition.merge("steps" => { "febre" => "x" }))
    a_triage!(day: day, protocol: broken, answers: { "febre" => "true" })
    a_triage!(day: day, protocol: v2, answers: { "febre" => "true" })

    run!

    expect(rows).to contain_exactly([ day, nil, v2.name, 2, "febre", "true", 1 ])
  end

  it "enum com null nas opções e resposta ausente não grava dim nulo" do
    definition = analytics_definition(name: "nulo")
    definition["steps"][1]["options"] = [ "Manchas", nil ]
    nullable = analytics_protocol!(name: "nulo", status: "draft")
    nullable.update_columns(definition: definition)
    a_triage!(day: day, protocol: nullable, answers: { "febre" => "true" })

    run!

    expect(rows).to contain_exactly([ day, nil, "nulo", 1, "febre", "true", 1 ])
  end

  it "triagem não concluída ou revogada não entra" do
    a_triage!(day: day, protocol: v2, status: "aborted_by_timeout", answers: { "febre" => "true" })
    a_triage!(day: day, protocol: v2, revoked: true, answers: { "febre" => "true" })

    run!

    expect(rows).to be_empty
  end
end
