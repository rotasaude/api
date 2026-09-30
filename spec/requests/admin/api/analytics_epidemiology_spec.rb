require "rails_helper"

# Contratos §1.4 e desvio 11 do plano: perguntas marcadas nas versões que
# passaram pelo ciclo; prompt e opções da maior dessas versões.
RSpec.describe "GET /admin/api/analytics/epidemiology", type: :request do
  let(:monday) { (Time.zone.today - 21).beginning_of_week }
  let(:range) { { from: monday.iso8601, to: (monday + 13).iso8601 } }
  let(:hidden) { { "suppressed" => true } }
  let(:centro) { Neighborhood.create!(name: "Centro", source: "manual") }

  def data = JSON.parse(response.body)["data"]

  def answer!(version, question, dim, value, day: monday, neighborhood: nil)
    fact!(metric: "epi.answer", day: day, value: value, protocol_name: "triagem-arbovirose", protocol_version: version,
          question_id: question, dim: dim, neighborhood_id: neighborhood&.id)
  end

  before do
    analytics_protocol!(version: 1, status: "retired", marks: %w[febre])
    definition = analytics_definition(version: 2)
    definition["steps"][0]["prompt"] = "Teve febre nos últimos 7 dias?"
    ProtocolDefinition.create!(name: "triagem-arbovirose", version: 2, status: "active", definition: definition)
    analytics_protocol!(version: 3, status: "draft", marks: %w[febre sintoma gestante]) # rascunho não nomeia
    create_default_protocol! # triage-respiratoria, sem marca
    consolidated_run!
    sign_in_as(staff_with("analise@cidade.gov.br", "analyst"))
    answer!(2, "febre", "true", 12)
    answer!(2, "febre", "false", 3)
    answer!(2, "sintoma", "Manchas", 7, day: monday + 8)
    answer!(1, "febre", "true", 5, neighborhood: centro)
  end

  it "uma entrada por pergunta marcada, com prompt e opções da versão mais recente do ciclo" do
    get "/admin/api/analytics/epidemiology", params: range

    expect(data["questions"]).to eq([
      { "protocol_name" => "triagem-arbovirose", "question_id" => "febre", "prompt" => "Teve febre nos últimos 7 dias?",
        "answer_type" => "boolean", "options" => [
          { "value" => "true", "label" => "Sim", "series" => [ 17, 0 ], "total" => 17 },
          { "value" => "false", "label" => "Não", "series" => [ hidden, 0 ], "total" => hidden }
        ] },
      { "protocol_name" => "triagem-arbovirose", "question_id" => "sintoma", "prompt" => "Qual o sintoma mais forte?",
        "answer_type" => "enum", "options" => [
          { "value" => "Manchas", "label" => "Manchas", "series" => [ 0, 7 ], "total" => 7 },
          { "value" => "Dor nas juntas", "label" => "Dor nas juntas", "series" => [ 0, 0 ], "total" => 0 },
          { "value" => "Nenhum", "label" => "Nenhum", "series" => [ 0, 0 ], "total" => 0 }
        ] }
    ])
  end

  it "total do grupo: série [10, oculto] esconde o total da opção" do
    answer!(2, "sintoma", "Dor nas juntas", 10)
    answer!(2, "sintoma", "Dor nas juntas", 3, day: monday + 8)

    get "/admin/api/analytics/epidemiology", params: range

    option = data["questions"].last["options"].find { |o| o["value"] == "Dor nas juntas" }
    expect(option).to include("series" => [ 10, hidden ], "total" => hidden)
  end

  it "recorte de versão: só as perguntas marcadas nela, ainda com o texto da mais recente" do
    get "/admin/api/analytics/epidemiology",
        params: range.merge(protocol_name: "triagem-arbovirose", protocol_version: "1")

    expect(data["questions"].map { |q| [ q["question_id"], q["prompt"] ] })
      .to eq([ [ "febre", "Teve febre nos últimos 7 dias?" ] ])
    expect(data["questions"].first["options"].first).to include("series" => [ 5, 0 ], "total" => 5)
  end

  it "recorte de bairro e protocolo sem pergunta marcada" do
    get "/admin/api/analytics/epidemiology", params: range.merge(neighborhood_id: centro.id)
    expect(data["questions"].first["options"].first["total"]).to eq(5)

    get "/admin/api/analytics/epidemiology", params: range.merge(protocol_name: "triage-respiratoria")
    expect(data["questions"]).to eq([])
  end

  # Contratos §1.4: as opções vêm da versão mais recente do ciclo. Opção que
  # uma versão nova tirou some da resposta, mesmo com fato das versões antigas
  # (comportamento documentado na verificação de 2026-09-30).
  it "opção removida numa versão mais nova: a série dela não aparece" do
    definition = analytics_definition(version: 4)
    definition["steps"][1]["options"] = [ "Dor nas juntas", "Nenhum", "Febre alta" ]
    definition["steps"][1]["branches"] = { "Dor nas juntas" => "gestante", "Nenhum" => "gestante", "Febre alta" => "gestante" }
    definition["steps"][1]["weights"] = { "Dor nas juntas" => 2, "Nenhum" => 0, "Febre alta" => 3 }
    ProtocolDefinition.create!(name: "triagem-arbovirose", version: 4, status: "published", definition: definition)

    get "/admin/api/analytics/epidemiology", params: range

    sintoma = data["questions"].find { |q| q["question_id"] == "sintoma" }
    expect(sintoma["options"].map { |o| o["value"] }).to eq([ "Dor nas juntas", "Nenhum", "Febre alta" ])
    expect(sintoma["options"].map { |o| o["total"] }).to eq([ 0, 0, 0 ]) # os 7 de "Manchas" (v2) não saem
  end

  # Desvio 11 do plano: a pergunta entra se ALGUMA versão do ciclo a marca;
  # prompt e opções vêm da maior versão que a marca. Desmarcar numa versão
  # nova não apaga o que a antiga contou.
  it "pergunta marcada na versão antiga e desmarcada na nova: continua, com o fato da antiga" do
    ProtocolDefinition.create!(name: "resp", version: 1, status: "retired",
                               definition: analytics_definition(name: "resp", marks: %w[gestante]))
    newer = analytics_definition(name: "resp", version: 2, marks: [])
    newer["steps"][2]["prompt"] = "Está grávida?"
    ProtocolDefinition.create!(name: "resp", version: 2, status: "active", definition: newer)
    fact!(metric: "epi.answer", day: monday, value: 6, protocol_name: "resp", protocol_version: 1,
          question_id: "gestante", dim: "true")

    get "/admin/api/analytics/epidemiology", params: range.merge(protocol_name: "resp")

    expect(data["questions"]).to eq([
      { "protocol_name" => "resp", "question_id" => "gestante", "prompt" => "Está gestante?", "answer_type" => "boolean",
        "options" => [
          { "value" => "true", "label" => "Sim", "series" => [ 6, 0 ], "total" => 6 },
          { "value" => "false", "label" => "Não", "series" => [ 0, 0 ], "total" => 0 }
        ] }
    ])
  end
end
