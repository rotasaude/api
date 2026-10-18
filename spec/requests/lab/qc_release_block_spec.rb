require "rails_helper"

# Spec §5.4–§5.6 e contrato §3 (F-21.29): com bloqueio ativo, o item do
# analito no aparelho não é liberado (409 qc_blocked, com os itens); o RT ou
# substituto libera exceção com justificativa (a liberação segue normal); o
# que saiu desde a última corrida aceita vai para revisão; a exceção é do
# bloqueio, não atravessa para o próximo; interruptor desligado não bloqueia.
RSpec.describe "CIQ — liberação bloqueada, exceção e revisão", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    travel_to(Time.zone.now.change(hour: 12))
    qc_city!
  end

  let(:s) { qc_scenario! }
  let!(:lead) { lab_releaser!(s.provider, council: "CRBM", lead: true) }
  let(:staff) { lab_staff! }

  # Tempo parado: um segundo entre valores (ordem da série) e 31 s entre liberações (TOTP novo).
  def qc!(level, z)
    travel 1.second
    qc_value!(s, level, z, by: staff)
  end

  def typed_item!
    req = received_requisition!(provider: s.provider, exams: [ s.exam ])
    type!(req.items.first, { glicose: "98" })
  end

  def release(item, user: lead)
    travel 31.seconds
    sign_in_as(user)
    json_post "/lab/requisitions/#{item.lab_requisition_id}/release", item_ids: [ item.id ], signature: "advanced", totp: totp_for(user)
  end

  it "reprovação bloqueia; exceção do RT libera; o já liberado entra na revisão; decisão uma vez" do
    qc!("Nível 1", 0.2)
    qc!("Nível 2", -0.3)
    first = typed_item!
    release(first)
    expect(response).to have_http_status(:created)
    report_id = json_body["id"]
    second = typed_item!
    Lab::Qc::OpenRun.call(instrument: s.instrument, by: staff)
    qc!("Nível 1", 3.6)
    block = LabQcBlock.active.sole
    expect(LabQcReviewItem.where(lab_qc_block: block).pluck(:lab_requisition_item_id, :decision)).to eq([ [ first.id, "pending" ] ])

    release(second)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "qc_blocked",
                            "items" => [ { "item_id" => second.id, "block_id" => block.id, "analyte_key" => "glicose", "instrument_id" => s.instrument.id,
                                           "instrument_name" => "Analisador bioquímico 1" } ])
    expect(second.reload.status).to eq("typed")

    stepped_up!(staff)
    json_post "/lab/qc/exceptions", block_id: block.id, item_id: second.id, justification: "Gestante em trabalho de parto"
    expect(response).to have_http_status(:forbidden)
    stepped_up!(lead)
    json_post "/lab/qc/exceptions", block_id: block.id, item_id: second.id, justification: " "
    expect(json_body["error"]).to eq("justification_required")
    json_post "/lab/qc/exceptions", block_id: block.id, item_id: second.id, justification: "x" * 1001 # C-E11
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["error"]).to eq("invalid_reason")
    json_post "/lab/qc/exceptions", block_id: block.id, item_id: second.id, justification: "Gestante em trabalho de parto"
    expect(response).to have_http_status(:created)
    expect(json_body).to include("block_id" => block.id, "item_id" => second.id, "justification" => "Gestante em trabalho de parto",
                                 "requisition_number" => second.lab_requisition.number, "sigtap_code" => "0202010473")
    json_post "/lab/qc/exceptions", block_id: block.id, item_id: second.id, justification: "De novo"
    expect(response).to have_http_status(:conflict)
    release(second)
    expect(response).to have_http_status(:created)

    stepped_up!(lead)
    get "/lab/qc/exceptions", params: { provider_id: s.provider.id, month: Time.zone.today.strftime("%Y-%m") }
    expect(json_body["exceptions"].map { |e| e["item_id"] }).to eq([ second.id ])
    get "/lab/qc/exceptions", params: { provider_id: s.provider.id, month: (Time.zone.today << 1).strftime("%Y-%m") }
    expect(json_body["exceptions"]).to eq([])
    get "/lab/qc/reviews", params: { provider_id: s.provider.id }
    review = json_body["reviews"].sole
    expect(review).to include("item_id" => first.id, "decision" => "pending", "analyte_key" => "glicose", "requisition_number" => first.lab_requisition.number,
                              "requisition_id" => first.lab_requisition_id, "exam_label" => "Glicose")
    json_post "/lab/qc/reviews/#{review['id']}", decision: "maybe"
    expect(json_body["error"]).to eq("invalid_decision")
    json_post "/lab/qc/reviews/#{review['id']}", decision: "kept", note: "x" * 1001 # C-E20
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["error"]).to eq("invalid_note")
    stepped_up!(lab_releaser!(s.provider)) # liberador sem ser RT nem substituto (C-E4)
    json_post "/lab/qc/reviews/#{review['id']}", decision: "kept"
    expect(response).to have_http_status(:forbidden)
    stepped_up!(lead)
    json_post "/lab/qc/reviews/#{review['id']}", decision: "rectify", note: "Repetir a dosagem"
    expect(json_body).to include("decision" => "rectify", "note" => "Repetir a dosagem", "report_id" => report_id)
    json_post "/lab/qc/reviews/#{review['id']}", decision: "kept"
    expect(response).to have_http_status(:conflict)
    payloads = DomainEvent.where("name LIKE 'lab_qc_%'").pluck(:payload).to_json
    expect(payloads).not_to include("Gestante", "Repetir")
    expect(DomainEvent.where(name: "lab_qc_review.decided").map(&:payload).sole.keys.sort).to eq(%w[decision lab_qc_review_item_id])
  end

  it "RT de outro laboratório: 404 na exceção, na revisão e na ação corretiva por id, sem gravar (C-E36)" do
    item = typed_item!
    qc!("Nível 1", 3.6)
    block = LabQcBlock.active.sole
    review = LabQcReviewItem.create!(lab_qc_block: block, lab_requisition_item_id: item.id)
    stepped_up!(lab_releaser!(lab_provider!, lead: true))
    json_post "/lab/qc/exceptions", block_id: block.id, item_id: item.id, justification: "Gestante em trabalho de parto"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    json_post "/lab/qc/reviews/#{review.id}", decision: "kept"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    json_post "/lab/qc/blocks/#{block.id}/corrective_action", text: "Calibração refeita"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    expect(LabQcException.count).to eq(0)
    expect(review.reload.decision).to eq("pending")
    expect(block.reload.corrective_action).to be_nil
  end

  it "exceção não atravessa bloqueio: fechado e reaberto, o item volta a ser recusado com o bloqueio novo" do
    qc!("Nível 1", 3.6)
    old_block = LabQcBlock.active.sole
    item = typed_item!
    expect(Lab::Qc::GrantException.call(block_id: old_block.id, item_id: item.id, justification: "Urgência", by: lead)).to be_ok
    travel 1.second
    Lab::Qc::RecordCorrectiveAction.call(block: old_block, text: "Calibração refeita", by: lead)
    qc!("Nível 1", 0.1)
    qc!("Nível 2", 0.2)
    expect(old_block.reload.closed_at).to be_present
    expect(Lab::Qc::GrantException.call(block_id: old_block.id, item_id: item.id, justification: "Urgência", by: lead).reason).to eq(:not_blocked)
    Lab::Qc::OpenRun.call(instrument: s.instrument, by: staff)
    qc!("Nível 2", -3.4)
    new_block = LabQcBlock.active.sole
    release(item)
    expect(response).to have_http_status(:conflict)
    expect(json_body["items"].map { |i| i["block_id"] }).to eq([ new_block.id ])
  end

  it "exceção só para item do aparelho e do analito do bloqueio ativo" do
    qc!("Nível 1", 3.6)
    block = LabQcBlock.active.sole
    untracked = lab_exam!(provider: s.provider, sigtap_code: "0202010317", name: "Creatinina", instrument_test_code: "CRE",
                          analytes: [ LabHelpers::GLUCOSE.first.merge("key" => "creatinina", "name" => "Creatinina", "decimals" => 2, "entry_min" => nil,
                                                                      "entry_max" => nil, "critical_low" => nil, "critical_high" => nil) ])
    req = received_requisition!(provider: s.provider, exams: [ untracked ])
    item = type!(req.items.first, { creatinina: "0,9" })
    expect(Lab::Qc::GrantException.call(block_id: block.id, item_id: item.id, justification: "x", by: lead).reason).to eq(:not_blocked)
    release(item)
    expect(response).to have_http_status(:created) # sem aparelho no exame: nunca bloqueado
  end

  it "com lab_quality_control desligado o bloqueio não é consultado" do
    qc!("Nível 1", 3.6)
    item = typed_item!
    Platform::Features.set!(city: City.find(Current.city.id), key: "lab_quality_control", enabled: false, maintainer: ledi_maintainer!)
    release(item)
    expect(response).to have_http_status(:created)
  end

  it "retificação com bloqueio ativo: sem exceção 409 qc_blocked; com a exceção do item e do bloqueio, sai (C-E19)" do
    qc!("Nível 1", 0.2)
    qc!("Nível 2", -0.3)
    item = typed_item!
    release(item)
    report_id = json_body["id"]
    Lab::Qc::OpenRun.call(instrument: s.instrument, by: staff)
    qc!("Nível 1", 3.6)
    block = LabQcBlock.active.sole
    expect(item.reload.status).to eq("released")
    sign_in_as(lead)
    json_post "/lab/results", item_id: item.id, values: [ { analyte_key: "glicose", value: "105" } ]
    expect(response).to have_http_status(:created)
    rectify = lambda do
      travel 31.seconds
      sign_in_as(lead)
      json_post "/lab/reports/#{report_id}/rectify", item_ids: [ item.id ], reason: "Erro de digitação do valor", signature: "advanced",
                                                     contacts: [ { person: "Dra. Helena", channel: "telefone", at: Time.current.iso8601 } ],
                                                     totp: totp_for(lead)
    end

    rectify.call
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "qc_blocked",
                            "items" => [ { "item_id" => item.id, "block_id" => block.id, "analyte_key" => "glicose", "instrument_id" => s.instrument.id,
                                           "instrument_name" => "Analisador bioquímico 1" } ])
    expect(LabReport.find(report_id).status).to eq("released")

    stepped_up!(lead)
    json_post "/lab/qc/exceptions", block_id: block.id, item_id: item.id, justification: "Retificação pedida pela unidade"
    expect(response).to have_http_status(:created)
    rectify.call
    expect(response).to have_http_status(:created)
    expect(json_body).to include("version" => 2, "replaces_report_id" => report_id)
    expect(LabReport.find(report_id).status).to eq("rectified")
  end
end
