require "rails_helper"

# Contrato §3 (F-21.27): valor como string com ponto (C-E9), corrida, regras
# por analito (RT, com justificativa ao desligar; C-E2, C-E11), bloqueios,
# contador sem trilha e ação corretiva de qualquer membro (C-E3, C-E4).
RSpec.describe "CIQ — corridas e bloqueios", type: :request do
  before { qc_city! }

  let(:s) { qc_scenario! }
  let(:staff) { lab_staff! }
  let(:lead) { lab_releaser!(s.provider, lead: true) }

  def post_value(level, value, run_id: nil)
    json_post "/lab/qc/values", run_id: run_id, instrument_id: s.instrument.id, lot_id: s.lot.id, level: level, analyte_key: "glicose", value: value
  end

  def dot(number) = Lab::Qc::Decimal.out(number)

  it "valor com ponto; corrida do dia; corrida a pedido; lista do dia" do
    sign_in_as(staff)
    post_value("Nível 1", "100.5")
    expect(response).to have_http_status(:created)
    expect(json_body["value"]).to include("value" => "100.5", "z_score" => 0.1, "outcome" => "ok", "rules_fired" => [], "source" => "typed",
                                          "target_version" => 1, "reagent_lot_id" => nil, "reagent_lot" => nil, "lot_id" => s.lot.id)
    expect(json_body["run"]).to include("status" => "approved", "instrument_id" => s.instrument.id)
    expect(json_body["run"]["values"].size).to eq(1)
    expect(json_body["block"]).to be_nil
    expect(json_body).not_to have_key("notice")
    json_post "/lab/qc/runs", instrument_id: s.instrument.id
    expect(response).to have_http_status(:created)
    opened = json_body
    expect(opened).to include("status" => "open", "values" => [])
    post_value("Nível 2", "250", run_id: opened["id"])
    expect(json_body["run"]["id"]).to eq(opened["id"])
    get "/lab/qc/runs", params: { instrument_id: s.instrument.id, date: Time.zone.today.iso8601 }
    expect(json_body["runs"].map { |r| r["values"].size }).to eq([ 1, 1 ])
    get "/lab/qc/runs", params: { instrument_id: s.instrument.id }
    expect(json_body["runs"].size).to eq(2)
    get "/lab/qc/runs", params: { instrument_id: s.instrument.id, date: (Time.zone.today - 1).iso8601 }
    expect(json_body["runs"]).to eq([])
    [ "2026-02-30", "18/10/2026" ].each do |bad|
      get "/lab/qc/runs", params: { instrument_id: s.instrument.id, date: bad }
      expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_date" ])
    end
  end

  it "C-E9: vírgula, formato fora de 9+4 ou vazio → invalid_value e nada gravado" do
    sign_in_as(staff)
    [ "98,5", "1,234", "98.55555", "1234567890", "", " 98.5", "1e3", 98.5 ].each do |raw|
      post_value("Nível 1", raw)
      expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_value" ])
    end
    expect(LabQcValue.count).to eq(0)
  end

  it "recusas da gravação: corrida inexistente, lote inexistente, aparelho inexistente, sem referência" do
    sign_in_as(staff)
    post_value("Nível 1", "100", run_id: "x")
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    post_value("Nível 1", "100", run_id: SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
    json_post "/lab/qc/values", instrument_id: s.instrument.id, lot_id: SecureRandom.uuid, level: "Nível 1", analyte_key: "glicose", value: "100"
    expect(response).to have_http_status(:not_found)
    json_post "/lab/qc/values", instrument_id: SecureRandom.uuid, lot_id: s.lot.id, level: "Nível 1", analyte_key: "glicose", value: "100"
    expect(response).to have_http_status(:not_found)
    json_post "/lab/qc/values", instrument_id: s.instrument.id, lot_id: s.lot.id, level: "Nível 1", analyte_key: "ureia", value: "100"
    expect([ response.status, json_body["error"] ]).to eq([ 422, "no_target" ])
    expect(LabQcValue.count).to eq(0)
  end

  it "reprovação → bloqueio listado e contado; aviso sem ação; ação corretiva de quem opera (C-E4), uma vez" do
    sign_in_as(staff)
    post_value("Nível 1", dot(qc_glucose("Nível 1", 3.5)))
    block = json_body["block"]
    expect(block).to include("analyte_key" => "glicose", "instrument_id" => s.instrument.id, "closed_at" => nil, "corrective_action" => nil)
    get "/lab/qc/blocks", params: { provider_id: s.provider.id }
    expect(json_body["blocks"].map { |b| b["id"] }).to eq([ block["id"] ])
    get "/lab/qc/blocks", params: { provider_id: s.provider.id, status: "closed" }
    expect(json_body["blocks"]).to eq([])
    get "/lab/qc/blocks/active/count"
    expect(json_body).to eq("count" => 1)
    # C-E3: corrida aceita completa sem ação → 201 com o aviso; o bloqueio continua.
    post_value("Nível 1", "100")
    post_value("Nível 2", "250")
    expect(response).to have_http_status(:created)
    expect(json_body).to include("notice" => "corrective_action_required")
    expect(json_body["block"]).to include("id" => block["id"], "closed_at" => nil)

    stepped_up!(lab_releaser!(lab_provider!))
    json_post "/lab/qc/blocks/#{block['id']}/corrective_action", text: "Calibração refeita"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ]) # liberador de outro laboratório (C-E36)
    get "/lab/qc/blocks/active/count"
    expect(json_body).to eq("count" => 0)
    sign_in_as(staff) # técnica do laboratório registra, sem step-up
    [ "  ", "x" * 1001 ].each do |text|
      json_post "/lab/qc/blocks/#{block['id']}/corrective_action", text: text
      expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_text" ])
    end
    json_post "/lab/qc/blocks/#{block['id']}/corrective_action", text: "Calibração refeita"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("corrective_action" => "Calibração refeita")
    json_post "/lab/qc/blocks/#{block['id']}/corrective_action", text: "Outra"
    expect(response).to have_http_status(:conflict)
    expect(DomainEvent.where(name: "lab_qc_block.action_recorded").map(&:payload)).to eq([ { "lab_qc_block_id" => block["id"] } ])
  end

  it "liberador (não RT) do laboratório também registra a ação corretiva (C-E4)" do
    block = qc_value!(s, "Nível 1", 3.5)[:block]
    sign_in_as(lab_releaser!(s.provider))
    json_post "/lab/qc/blocks/#{block.id}/corrective_action", text: "Reagente trocado"
    expect(response).to have_http_status(:ok)
  end

  it "contador não grava trilha" do
    qc_value!(s, "Nível 1", 3.5)
    sign_in_as(staff)
    expect { get "/lab/qc/blocks/active/count" }.not_to(change { DomainEvent.count })
    expect(json_body).to eq("count" => 1)
  end

  it "regras de aparelho de outro laboratório: 404 na leitura e na mudança (C-E36)" do
    stepped_up!(lab_releaser!(lab_provider!, lead: true))
    get "/lab/qc/rules", params: { instrument_id: s.instrument.id, analyte_key: "glicose" }
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    json_put "/lab/qc/rules", instrument_id: s.instrument.id, analyte_key: "glicose", rules: LabQcRule::RULES.index_with(true), justification: nil
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    expect(LabQcRule.count).to eq(0)
  end

  it "regras: padrão todas ligadas; só o RT muda; desligar exige justificativa" do
    sign_in_as(staff)
    get "/lab/qc/rules", params: { instrument_id: s.instrument.id, analyte_key: "glicose" }
    expect(json_body).to include("is_default" => true, "rules" => LabQcRule::RULES.index_with(true))
    stepped_up!(staff)
    json_put "/lab/qc/rules", instrument_id: s.instrument.id, analyte_key: "glicose", rules: LabQcRule::RULES.index_with(true), justification: nil
    expect(response).to have_http_status(:forbidden)
    stepped_up!(lead)
    off = LabQcRule::RULES.index_with(true).merge("10x" => false)
    json_put "/lab/qc/rules", instrument_id: s.instrument.id, analyte_key: "glicose", rules: off, justification: ""
    expect(json_body["error"]).to eq("justification_required")
    json_put "/lab/qc/rules", instrument_id: s.instrument.id, analyte_key: "glicose", rules: off, justification: "x" * 1001
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_reason" ]) # C-E11
    json_put "/lab/qc/rules", instrument_id: s.instrument.id, analyte_key: "glicose", rules: off.except("10x"), justification: "x"
    expect(json_body["error"]).to eq("invalid_rules")
    json_put "/lab/qc/rules", instrument_id: s.instrument.id, analyte_key: "glicose", rules: off.merge("10x" => "false"), justification: "x"
    expect(json_body["error"]).to eq("invalid_rules")
    json_put "/lab/qc/rules", instrument_id: s.instrument.id, analyte_key: "glicose", rules: off, justification: "Lote novo em validação"
    expect(json_body).to include("is_default" => false, "justification" => "Lote novo em validação")
    expect(json_body["rules"]["10x"]).to be(false)
    # C16/C-E2: religar não exige justificativa; manter desligada a mesma regra também não.
    json_put "/lab/qc/rules", instrument_id: s.instrument.id, analyte_key: "glicose", rules: off.merge("2_2s" => true), justification: nil
    expect(response).to have_http_status(:ok)
    json_put "/lab/qc/rules", instrument_id: s.instrument.id, analyte_key: "glicose", rules: LabQcRule::RULES.index_with(true), justification: nil
    expect(json_body["is_default"]).to be(false)
    # D3: três gravações, três eventos, um por versão.
    events = DomainEvent.where(name: "lab_qc_rule.changed").map(&:payload)
    expect(events.map { |p| p.keys.sort }).to eq([ %w[lab_instrument_id lab_qc_rule_id] ] * 3)
    expect(events.map { |p| p["lab_qc_rule_id"] }.uniq.size).to eq(3)
    expect(LabQcRule.count).to eq(3)
  end

  it "quem não é do laboratório não grava valor nem abre corrida: 404 (C-E36); admin lê mas não opera: 403" do
    stepped_up!(lab_releaser!(lab_provider!))
    post_value("Nível 1", "100")
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    json_post "/lab/qc/runs", instrument_id: s.instrument.id
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    get "/lab/qc/runs", params: { instrument_id: s.instrument.id }
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])

    stepped_up!(lab_admin!)
    post_value("Nível 1", "100")
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    json_post "/lab/qc/runs", instrument_id: s.instrument.id
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    expect(LabQcRun.count).to eq(0)
    expect(LabQcValue.count).to eq(0)
  end

  it "valor com lote de controle de outro laboratório: 404, sem revelar o lote (C-E36)" do
    other = qc_scenario!(provider: lab_provider!)
    sign_in_as(lab_releaser!(s.provider)) # liberador ligado só ao laboratório do aparelho (lab_staff lê todos)
    json_post "/lab/qc/values", instrument_id: s.instrument.id, lot_id: other.lot.id, level: "Nível 1", analyte_key: "glicose", value: "100"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    expect(LabQcValue.count).to eq(0)
  end
end
