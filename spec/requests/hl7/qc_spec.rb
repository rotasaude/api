require "rails_helper"

# Spec §7 e contrato §6 (F-21.28; Task 0): o SPM-2 = código de barras de
# nível de lote de controle cadastrado decide que é controle; aparelho pela
# repetição de OBX-18; cada valor avaliado por Westgard; reprovação não muda
# o ACK; controle nunca vira resultado de paciente (Review Focus 2);
# recusas AE todas de uma vez; mensagem inteira ou nada.
RSpec.describe "HL7 — controle de qualidade", type: :request do
  before { qc_city!(hl7: true) }

  let(:provider) { lab_provider! }
  let(:instrument) { qc_instrument!(provider) } # BIO-01
  let(:exam) { qc_exam!(provider: provider, instrument: instrument) } # GLI
  let(:material) { qc_material!(provider, exams: [ exam ]) }
  let(:lot) { qc_lot!(material, lot_number: "CQB-2611", barcodes: { "Nível 1" => "CQB2611N1", "Nível 2" => "CQB2611N2" }) }
  let!(:targets) do
    [ [ "Nível 1", "90", "4.5" ], [ "Nível 2", "270", "13.5" ] ].map do |level, mean, sd|
      qc_target!(lot, level: level, analyte_key: "glicose", instrument: instrument, mean: mean, sd: sd)
    end
  end
  let(:token) { middleware_token!(provider) }

  def fixture(name) = File.binread(Rails.root.join("spec/fixtures/lab", name))
  def oul(*segments) = ([ "MSH|^~\\&|MW|LAB|ROTA-SAUDE|t|20261018073000||OUL^R22^OUL_R22|C#{SecureRandom.hex(4)}|P|2.5.1" ] + segments).join("\r") + "\r"
  def spm(i, barcode, role: "Q") = "SPM|#{i}|#{barcode}|||||||||#{role}"
  def obr(i, code = "GLI") = "OBR|#{i}|||#{code}^#{code}^99RSL"
  def obx(i, value, equipment: "BIO-01", key: "glicose") = "OBX|#{i}|NM|#{key}^G^99RSL||#{value}|mg/dL^^UCUM|||||F|||20261018072500||||#{equipment}"
  def msa = response.body.split("\r").find { |s| s.start_with?("MSA|") }.split("|")[1]
  def errs = response.body.split("\r").select { |s| s.start_with?("ERR|") }
  def err5 = errs.map { |e| [ e.split("|")[2], e.split("|")[5].split("^").first ] }

  it "exemplo aprovado do contracts: AA, dois valores na mesma corrida, nada de paciente" do
    hl7_post(fixture("oul-r22-qc.hl7"), token: token)
    expect(msa).to eq("AA")
    values = LabQcValue.order(:level).to_a
    expect(values.map { |v| [ v.level, v.z_score, v.outcome, v.source ] })
      .to eq([ [ "Nível 1", BigDecimal("0.4"), "ok", "hl7" ], [ "Nível 2", BigDecimal("-0.6"), "ok", "hl7" ] ])
    expect(values.map(&:lab_qc_run_id).uniq.size).to eq(1)
    expect(values.first.lab_qc_run.status).to eq("approved")
    expect(values.map(&:lab_hl7_receipt_id).uniq.size).to eq(1)
    expect(LabResult.count).to eq(0)
  end

  it "exemplo 2-2s do contracts: AA (a mensagem é aceita), corrida reprovada e bloqueio" do
    hl7_post(fixture("oul-r22-qc-2-2s.hl7"), token: token)
    expect(msa).to eq("AA")
    level2 = LabQcValue.find_by!(level: "Nível 2")
    expect(level2.rules_fired).to eq(%w[1_2s 2_2s])
    expect(level2.lab_qc_run.status).to eq("rejected")
    expect(LabQcBlock.active.sole).to have_attributes(lab_instrument_id: instrument.id, analyte_key: "glicose")
  end

  it "controle nunca vira paciente" do
    # Sem SPM-11, ou com P: o código de barras de controle decide.
    hl7_post(oul(spm(1, "CQB2611N1", role: ""), obr(1), obx(1, "90.0")), token: token)
    expect(msa).to eq("AA")
    hl7_post(oul(spm(1, "CQB2611N2", role: "P"), obr(1), obx(1, "270.0")), token: token)
    expect(msa).to eq("AA")
    expect(LabQcValue.count).to eq(2)
    # Q com código de amostra de paciente: recusado, nada gravado.
    req = received_requisition!(provider: provider, exams: [ exam ])
    patient_barcode = req.samples.first.barcode
    hl7_post(oul(spm(1, patient_barcode, role: "Q"), obr(1), "OBX|1|NM|glicose^G^99RSL||98|mg/dL|||||F"), token: token)
    expect([ msa, err5 ]).to eq([ "AE", [ [ "SPM^1^2", "unknown_barcode" ] ] ])
    expect(LabResult.count).to eq(0)
    # Controle e paciente juntos: os dois entram; erro no controle derruba os dois.
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "91.8"), "SPM|2|#{patient_barcode}", obr(1), "OBX|1|NM|glicose^G^99RSL||98|mg/dL|||||F"),
             token: token)
    expect(msa).to eq("AA")
    expect([ LabResult.count, LabQcValue.count ]).to eq([ 1, 3 ])
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "91.8", equipment: "XX"), "SPM|2|#{patient_barcode}", obr(1),
                 "OBX|1|NM|glicose^G^99RSL||99|mg/dL|||||F"), token: token)
    expect(msa).to eq("AE")
    expect([ LabResult.count, LabQcValue.count ]).to eq([ 1, 3 ])
  end

  # C-E23: controles antes das amostras de paciente, na mesma transação; a
  # mensagem inteira ou nada nos dois sentidos; código procurado sem caixa (C-E13).
  it "mensagem mista: recusa do paciente desfaz o controle; controle por código minúsculo" do
    req = received_requisition!(provider: provider, exams: [ exam ])
    patient_barcode = req.samples.first.barcode
    hl7_post(oul(spm(1, "cqb2611n1"), obr(1), obx(1, "91.8", equipment: "bio-01"), "SPM|2|#{patient_barcode}", obr(1),
                 "OBX|1|NM|glicose^G^99RSL||98|mg/dL|||||F", "SPM|3|0000000000", obr(1), "OBX|1|NM|glicose^G^99RSL||98|mg/dL|||||F"),
             token: token)
    expect([ msa, err5 ]).to eq([ "AE", [ [ "SPM^3^2", "unknown_barcode" ] ] ])
    expect([ LabResult.count, LabQcValue.count, LabQcRun.count, LabHl7Receipt.count ]).to eq([ 0, 0, 0, 0 ])

    hl7_post(oul(spm(1, "cqb2611n1"), obr(1), obx(1, "91.8", equipment: "bio-01"), "SPM|2|#{patient_barcode}", obr(1),
                 "OBX|1|NM|glicose^G^99RSL||98|mg/dL|||||F"), token: token)
    expect(msa).to eq("AA")
    expect([ LabResult.count, LabQcValue.count ]).to eq([ 1, 1 ])
    expect(LabQcValue.sole).to have_attributes(level: "Nível 1", source: "hl7", lab_hl7_receipt_id: LabHl7Receipt.sole.id)
  end

  it "nada do controle (código de barras, valor, aparelho, código do exame, token) vai ao log" do
    log = capture_log do
      hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "93.7", equipment: "bio-01")), token: token)
      hl7_post(oul(spm(1, "CQB2611N2"), obr(1), obx(1, "271.3", equipment: "ZQ-UNKNOWN-77")), token: token)
      hl7_post(oul(spm(1, "CQB2611N2"), obr(1, "XQZ9"), obx(1, "271.3")), token: token)
    end
    expect(err5).to eq([ [ "OBR^1^4", "exam_not_in_version" ] ])
    [ "CQB2611N1", "cqb2611n1", "CQB2611N2", "cqb2611n2", "93.7", "271.3", "BIO-01", "bio-01", "ZQ-UNKNOWN-77", "XQZ9", "GLI",
      "OBX|", "MSH|", token ].each do |leak|
      expect(log).not_to include(leak)
    end
  end

  it "código de 10 dígitos (amostra de paciente) nem consulta os códigos de controle; com Q, unknown_barcode" do
    req = received_requisition!(provider: provider, exams: [ exam ])
    patient_barcode = req.samples.first.barcode
    expect(LabQcLotBarcode).not_to receive(:matching)
    hl7_post(oul(spm(1, patient_barcode, role: "Q"), obr(1), "OBX|1|NM|glicose^G^99RSL||98|mg/dL|||||F"), token: token)
    expect([ msa, err5 ]).to eq([ "AE", [ [ "SPM^1^2", "unknown_barcode" ] ] ])
    hl7_post(oul("SPM|1|#{patient_barcode}", obr(1), "OBX|1|NM|glicose^G^99RSL||98|mg/dL|||||F"), token: token)
    expect(msa).to eq("AA")
    expect([ LabResult.count, LabQcValue.count ]).to eq([ 1, 0 ])
  end

  # Como o paciente (E5/B26), que deduplica a mensagem inteira: a ordem não decide qual vale.
  it "o mesmo nível, analito e aparelho duas vezes na mensagem (outro OBR ou outro SPM): invalid_value" do
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "90.0"), obr(2), obx(2, "91.0")), token: token)
    expect([ msa, err5 ]).to eq([ "AE", [ [ "OBX^2^5", "invalid_value" ] ] ])
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "90.0"), spm(2, "cqb2611n1"), obr(2), obx(2, "91.0")), token: token)
    expect([ msa, err5 ]).to eq([ "AE", [ [ "OBX^2^5", "invalid_value" ] ] ])
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "90.0"), obx(2, "90.5")), token: token)
    expect([ msa, err5 ]).to eq([ "AE", [ [ "OBX^2^5", "invalid_value" ] ] ])
    expect(LabQcValue.count).to eq(0)
    # Níveis diferentes do mesmo analito na mesma mensagem continuam valendo.
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "90.0"), spm(2, "CQB2611N2"), obr(2), obx(2, "270.0")), token: token)
    expect(msa).to eq("AA")
    expect(LabQcValue.count).to eq(2)
  end

  it "INV (CO, validade, lote) e SPM-4 do controle são ignorados; o valor é gravado" do
    inv = [ "INV", "GLI^Glicose^99RSL", "OK^Ok^HL70383", "CO^Control^HL70384", "", "", "", "", "", "", "", "", "20270101", "", "", "", "CQB-2611" ].join("|")
    hl7_post(oul("SPM|1|CQB2611N1||SER^Soro^HL70487|||||||Q", inv, obr(1), obx(1, "91.8")), token: token)
    expect(msa).to eq("AA")
    expect(LabQcValue.sole).to have_attributes(level: "Nível 1", value: BigDecimal("91.8"), z_score: BigDecimal("0.4"), lab_qc_lot_id: lot.id)
    expect(LabResult.count).to eq(0)
  end

  it "controle recusado: o paciente da mesma mensagem é só conferido (sem gravar resultado)" do
    req = received_requisition!(provider: provider, exams: [ exam ])
    expect(Lab::EnterResults).not_to receive(:call)
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "91.8", equipment: "XX"), "SPM|2|#{req.samples.first.barcode}", obr(1),
                 "OBX|1|NM|glicose^G^99RSL||98|mg/dL|||||F|||"), token: token)
    expect([ msa, err5 ]).to eq([ "AE", [ [ "OBX^1^18", "unknown_instrument" ] ] ])
  end

  it "todas as recusas de uma vez, como o exemplo ack-ae-qc do contracts" do
    expired = qc_lot!(material, lot_number: "CQV-1", expires_on: Time.zone.today - 1, barcodes: { "Nível 1" => "CQV1N1", "Nível 2" => "CQV1N2" })
    qc_target!(expired, level: "Nível 1", analyte_key: "glicose", instrument: instrument, mean: 90, sd: 4.5)
    hl7_post(oul(spm(1, "CQV1N1"), obr(1), obx(1, "90.0"), spm(2, "CQB2611N2"), obr(2), obx(2, "270.0", equipment: "XX")), token: token)
    expect(msa).to eq("AE")
    expect(errs).to eq(fixture("ack-ae-qc.hl7").split("\r").select { |s| s.start_with?("ERR|") })
    expect(LabQcValue.count).to eq(0)
  end

  it "recusas: lote encerrado, sem referência, analito, aparelho ausente, vírgula, controle desligado" do
    qc_instrument!(provider, name: "Analisador bioquímico 2", hl7_equipment_id: "BIO-02")
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "90.0", equipment: "BIO-02"), obx(2, "90.0", key: "ureia"), obx(3, "90,5"),
                 obx(4, "90.0", equipment: "")), token: token)
    expect(msa).to eq("AE")
    expect(err5).to eq([ [ "OBX^1^3", "qc_no_target" ], [ "OBX^2^3", "unknown_analyte" ], [ "OBX^3^5", "invalid_value" ],
                         [ "OBX^4^18", "unknown_instrument" ] ])
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1, "XYZ"), obx(1, "90.0")), token: token)
    expect(err5).to eq([ [ "OBR^1^4", "exam_not_in_version" ] ])
    lot.update!(status: "closed", closed_on: Time.zone.today)
    hl7_post(oul(spm(1, "CQB2611N1"), obr(1), obx(1, "90.0")), token: token)
    expect(err5).to eq([ [ "SPM^1^2", "qc_lot_closed" ] ])
    Platform::Features.set!(city: City.find(Current.city.id), key: "lab_quality_control", enabled: false, maintainer: ledi_maintainer!)
    hl7_post(oul(spm(1, "CQB2611N2"), obr(1), obx(1, "270.0")), token: token)
    expect(err5).to eq([ [ "SPM^1^2", "qc_disabled" ] ])
    expect(LabQcValue.count).to eq(0)
  end
end
