require "rails_helper"

# Contrato §7 com D1/D2/D3 (perfil rotasaude.lab.hl7.v1). Review Focus 1:
# troca de amostra; tudo ou nada; MSH-10 repetido; token revogado; bruto cifrado.
RSpec.describe "HL7 v2 — entrada do middleware", type: :request do
  before { lab_city!(hl7: true) }

  let(:provider) { lab_provider! }
  let(:glucose) { lab_exam!(provider: provider) }
  let(:req) { received_requisition!(provider: provider, exams: [ glucose ]) }
  let(:barcode) { req.samples.first.barcode }
  let!(:token) { middleware_token!(provider) }

  def oul(barcode:, control: "M#{SecureRandom.hex(4)}", obr: "GLI", obx: [ "OBX|1|NM|glicose^Glicose^99RSL||98|mg/dL^^UCUM|||||F" ])
    ([ "MSH|^~\\&|MW|LAB|ROTA-SAUDE|test|20261015150000||OUL^R22^OUL_R22|#{control}|P|2.5.1",
       "SPM|1|#{barcode}||Plasma^^99RSL", "OBR|1|||#{obr}^Glicose^99RSL" ] + obx).join("\r") + "\r"
  end

  def msa = response.body.split("\r").find { |s| s.start_with?("MSA") }.split("|")[1]
  def err5 = response.body.split("\r").find { |s| s.start_with?("ERR") }&.split("|")&.at(5)&.split("^")&.first

  it "QBP^Q11 devolve a lista de trabalho; código desconhecido AE" do
    qbp = "MSH|^~\\&|MW|LAB|ROTA-SAUDE|test|20261015150000||QBP^Q11^QBP_Q11|Q1|P|2.5.1\rQPD|LabWorklist^Lista de trabalho^99RSL|T1|#{barcode}\rRCP|I\r"
    hl7_post(qbp, token: token)
    expect(response.media_type).to eq("application/hl7-v2")
    expect(msa).to eq("AA")
    expect(response.body).to include("OBR|1|#{req.items.first.id}||GLI^Glicose^99RSL")
    expect(response.body).not_to include(req.patient.display_name.to_s)
    hl7_post(qbp.sub(barcode, "0000000000"), token: token)
    expect([ msa, err5 ]).to eq([ "AE", "unknown_barcode" ])
  end

  it "OUL^R22 aceita, idempotente por MSH-10, bruto cifrado, nunca liberado" do
    hl7_post(oul(barcode: barcode, control: "M1"), token: token)
    expect(msa).to eq("AA")
    row = LabResult.sole
    expect(row).to have_attributes(source: "hl7", value: "98", entered_by_user_id: nil)
    receipt = LabHl7Receipt.sole
    raw = ApplicationRecord.connection.select_value("SELECT raw FROM lab_hl7_receipts WHERE id = #{ApplicationRecord.connection.quote(receipt.id)}")
    expect(raw).not_to include(barcode)
    hl7_post(oul(barcode: barcode, control: "M1", obx: [ "OBX|1|NM|glicose^Glicose^99RSL||300|mg/dL^^UCUM|||||F" ]), token: token)
    expect(msa).to eq("AA")
    expect(LabResult.count).to eq(1)
    expect(ExamResult.count).to eq(0)
    expect(req.items.first.reload.status).to eq("typed")
  end

  it "troca de amostra e recusas: AE e nada gravado (tudo ou nada)" do
    other_lab = lab_provider!
    foreign = received_requisition!(provider: other_lab, exams: [ lab_exam!(provider: other_lab) ])
    rejected = open_requisition!(provider: provider, exams: [ glucose ])
    staff = lab_staff!
    Lab::CollectSample.call(sample: rejected.samples.first, by: staff)
    Lab::ReceiveSample.call(barcode: rejected.samples.first.barcode, decision: "reject", by: staff,
                            reason_id: LabRejectionReason.create!(exam_provider: provider, name: "Hemólise").id)
    cases = {
      oul(barcode: foreign.samples.first.barcode) => "unknown_barcode",
      oul(barcode: rejected.samples.first.barcode) => "sample_not_received",
      oul(barcode: barcode, obr: "OLD") => "exam_not_in_version",
      oul(barcode: barcode, obx: [ "OBX|1|NM|ldl^LDL^99RSL||1|mg/dL^^UCUM|||||F" ]) => "unknown_analyte",
      oul(barcode: barcode, obx: [ "OBX|1|NM|glicose^Glicose^99RSL||1600|mg/dL^^UCUM|||||F" ]) => "out_of_entry_range",
      oul(barcode: barcode, obx: [ "OBX|1|NM|glicose^Glicose^99RSL||5|mmol/L^^UCUM|||||F" ]) => "unit_mismatch",
      oul(barcode: barcode, obx: [ "OBX|1|NM|glicose^Glicose^99RSL||98|mg/dL^^UCUM|||||F", "OBX|2|NM|glicose^Glicose^99RSL||abc|mg/dL^^UCUM|||||F" ]) => "invalid_value"
    }
    cases.each do |body, code|
      hl7_post(body, token: token)
      expect([ msa, err5 ]).to eq([ "AE", code ]), code
    end
    expect(LabResult.count).to eq(0)
    expect(LabHl7Receipt.count).to eq(0)
    hl7_post(oul(barcode: barcode).sub("2.5.1", "2.3.1"), token: token)
    expect([ msa, err5 ]).to eq([ "AR", "unsupported_version" ])
    hl7_post(oul(barcode: barcode).sub("OUL^R22^OUL_R22", "OML^O33^OML_O33"), token: token)
    expect([ msa, err5 ]).to eq([ "AR", "unsupported_message_type" ])
  end

  it "token: sem ou desconhecido 401; revogado AR; simulado sem fake_middleware AR; tipo e tamanho" do
    hl7_post(oul(barcode: barcode), token: nil)
    expect(response).to have_http_status(:unauthorized)
    hl7_post(oul(barcode: barcode), token: "x" * 40)
    expect(response).to have_http_status(:unauthorized)
    Lab::RotateMiddlewareToken.revoke(provider: provider)
    hl7_post(oul(barcode: barcode), token: token)
    expect([ response.status, msa, err5 ]).to eq([ 200, "AR", "token_revoked" ])
    simulated = middleware_token!(provider, simulated: true)
    hl7_post(oul(barcode: barcode), token: simulated)
    expect([ msa, err5 ]).to eq([ "AR", "feature_disabled" ])
    post "/hl7/v2", params: oul(barcode: barcode), headers: { "CONTENT_TYPE" => "text/plain", "Authorization" => "Bearer #{simulated}" }
    expect(response).to have_http_status(:unsupported_media_type)
    hl7_post("MSH|^~\\&|" + ("x" * 1_048_577), token: simulated)
    expect(response).to have_http_status(:payload_too_large)
  end

  it "lista de pendentes para o middleware (só códigos)" do
    req
    get "/lab/hl7/pending_barcodes", headers: { "Authorization" => "Bearer #{token}" }
    expect(JSON.parse(response.body)).to eq("barcodes" => [ barcode ])
    Platform::Features.set!(city: City.find(Current.city.id), key: "lab_hl7_inbound", enabled: false, maintainer: ledi_maintainer!)
    hl7_post(oul(barcode: barcode), token: token)
    expect(response).to have_http_status(:forbidden)
  end

  it "B26: um ERR por recusa, na ordem dos segmentos, e nada gravado" do
    body = oul(barcode: barcode, obx: [ "OBX|1|NM|glicose^Glicose^99RSL||1600|mg/dL^^UCUM|||||F",
                                        "OBX|2|NM|ldl^LDL^99RSL||1|mg/dL^^UCUM|||||F",
                                        "OBX|3|NM|glicose^Glicose^99RSL||98|mg/dL^^UCUM|||||F" ])
    hl7_post(body, token: token)
    errs = response.body.split("\r").select { |s| s.start_with?("ERR") }.map { |s| f = s.split("|"); [ f[2], f[5].split("^").first ] }
    expect(errs).to eq([ [ "OBX^1^5", "out_of_entry_range" ], [ "OBX^2^3", "unknown_analyte" ], [ "OBX^3^5", "invalid_value" ] ])
    expect([ LabResult.count, LabHl7Receipt.count ]).to eq([ 0, 0 ])
  end

  it "B54: item de laudo ICP à espera da assinatura não aceita resultado pela HL7 (item_not_open)" do
    item = type!(req.items.first, { glicose: 98 })
    report = LabReport.create!(lab_requisition: req, exam_provider: provider, version: 1, partial: false, status: "pending_signature",
                               signature_kind: "icp", released_by_user: lab_releaser!(provider, council: "CRM"), content: "{}",
                               content_sha256: "a" * 64, verification_token: ClinicalDocuments::Codes.token,
                               short_code: ClinicalDocuments::Codes.short_code)
    LabReportItem.create!(lab_report: report, lab_requisition_item: item)
    hl7_post(oul(barcode: barcode), token: token)
    expect([ msa, err5 ]).to eq([ "AE", "item_not_open" ])
    expect([ LabResult.count, LabHl7Receipt.count ]).to eq([ 1, 0 ])
  end

  it "E6: item liberado ou cancelado não aceita resultado pela HL7 (item_not_open)" do
    item = req.items.first
    type!(item, { glicose: 98 })
    item.update_columns(status: "released")
    hl7_post(oul(barcode: barcode), token: token)
    expect([ msa, err5 ]).to eq([ "AE", "item_not_open" ])
    item.update_columns(status: "cancelled")
    hl7_post(oul(barcode: barcode), token: token)
    expect([ msa, err5 ]).to eq([ "AE", "item_not_open" ])
    expect(LabResult.count).to eq(1)
    expect(LabHl7Receipt.count).to eq(0)
  end

  it "mensagem malformada: AR invalid_message" do
    hl7_post("lixo sem MSH", token: token)
    expect([ msa, err5 ]).to eq([ "AR", "invalid_message" ])
  end

  it "pendentes: só do laboratório do token, sem amostra de outro" do
    other = lab_provider!
    received_requisition!(provider: other, exams: [ lab_exam!(provider: other) ])
    req
    get "/lab/hl7/pending_barcodes", headers: { "Authorization" => "Bearer #{token}" }
    expect(JSON.parse(response.body)["barcodes"]).to eq([ barcode ])
    get "/lab/hl7/pending_barcodes"
    expect(response).to have_http_status(:unauthorized)
  end

  it "nada da mensagem (código de barras, valor, token) vai ao log" do
    log = capture_log do
      hl7_post(oul(barcode: barcode, obx: [ "OBX|1|NM|glicose^Glicose^99RSL||1234.5|mg/dL^^UCUM|||||F" ]), token: token)
      hl7_post(oul(barcode: barcode, control: "M2"), token: token)
      get "/lab/hl7/pending_barcodes", headers: { "Authorization" => "Bearer #{token}" }
    end
    expect(log).not_to include(barcode)
    expect(log).not_to include("1234.5")
    expect(log).not_to include("OBX|")
    expect(log).not_to include("MSH|")
    expect(log).not_to include(token)
  end

  it "I1: corpo com outro Content-Type nunca chega ao log (info e debug)" do
    msg = oul(barcode: barcode, obx: [ "OBX|1|NM|glicose^Glicose^99RSL||1234.5|mg/dL^^UCUM|||||F" ])
    [ "application/x-www-form-urlencoded", "application/json" ].each do |type|
      [ Logger::INFO, Logger::DEBUG ].each do |level|
        old = Rails.logger.level
        Rails.logger.level = level
        log = capture_log { post "/hl7/v2", params: msg, headers: { "CONTENT_TYPE" => type, "Authorization" => "Bearer #{token}" } }
        Rails.logger.level = old
        expect(response).to have_http_status(:unsupported_media_type)
        [ barcode, "1234.5", "MSH|", "OBX|", token ].each { |leak| expect(log).not_to include(leak), "#{type} #{level}" }
      end
    end
  end

  it "B50: estrutura inválida é sempre AR, mesmo com SPM e com recusas de conteúdo" do
    orphan = "MSH|^~\\&|MW|LAB|ROTA-SAUDE|test|20261015150000||OUL^R22^OUL_R22|MO1|P|2.5.1\rOBR|1|||GLI^Glicose^99RSL\r" +
             oul(barcode: barcode).split("\r").drop(1).join("\r") + "\r"
    hl7_post(orphan, token: token)
    expect([ msa, err5 ]).to eq([ "AR", "invalid_message" ])
    expect(response.body).to include("ERR||OBR^1^1|")
    expect(LabResult.count).to eq(0)
  end

  it "I2: SPM 1 válido e SPM 2 recusado: nada gravado, item pendente, sem evento" do
    other = received_requisition!(provider: provider, exams: [ glucose ])
    second = other.samples.first.barcode
    body = oul(barcode: barcode, control: "M7").chomp("\r") + "\r" +
           "SPM|2|#{second}||Plasma^^99RSL\rOBR|2|||GLI^Glicose^99RSL\rOBX|1|NM|glicose^Glicose^99RSL||1600|mg/dL^^UCUM|||||F\r"
    events = DomainEvent.count
    hl7_post(body, token: token)
    expect([ msa, err5 ]).to eq([ "AE", "out_of_entry_range" ])
    expect([ LabResult.count, LabHl7Receipt.count, DomainEvent.count ]).to eq([ 0, 0, events ])
    expect(req.items.first.reload.status).to eq("pending")
  end

  it "dois OBR do mesmo exame na mensagem: invalid_value no segundo" do
    body = oul(barcode: barcode).chomp("\r") + "\rOBR|2|||GLI^Glicose^99RSL\rOBX|1|NM|glicose^Glicose^99RSL||99|mg/dL^^UCUM|||||F\r"
    hl7_post(body, token: token)
    expect([ msa, err5 ]).to eq([ "AE", "invalid_value" ])
    expect(response.body).to include("ERR||OBR^2^4|")
    expect(LabResult.count).to eq(0)
  end
end
