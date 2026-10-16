require "rails_helper"

# ADR 0037, Invariantes, provados de ponta a ponta num fluxo inteiro: cada um
# tenta a escrita proibida e espera a recusa do banco ou da aplicação.
RSpec.describe "Invariantes do laboratório municipal (ADR 0037)", type: :request do
  before { lab_city!(hl7: true) }

  let(:provider) { lab_provider! }
  let(:lead) { lab_releaser!(provider, lead: true) }
  let(:req) { received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ]) }
  let(:token) { middleware_token!(provider) }

  def oul(value, control) = "MSH|^~\\&|MW|LAB|ROTA-SAUDE|t|20261015150000||OUL^R22^OUL_R22|#{control}|P|2.5.1\rSPM|1|#{req.samples.first.barcode}\rOBR|1|||GLI\rOBX|1|NM|glicose^G^99RSL||#{value}|mg/dL|||||F\r"

  def release!(item) = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(lead), by: lead)

  it "resultado de aparelho nunca liberado sozinho; não liberado não sai; valores fora de eventos e log" do
    log = capture_log { hl7_post(oul("123", "I1"), token: token) }
    item = req.items.first.reload
    expect(item.status).to eq("typed")
    expect(ExamResult.where(exam_order_id: item.exam_order_id)).to be_empty
    expect(LabReport.count).to eq(0)
    report = release!(item).payload[:report]
    expect(report.status).to eq("released")
    payloads = DomainEvent.where("name LIKE 'lab_%' OR name LIKE 'exam_order.%'").pluck(:payload).to_json
    [ "123", req.patient.cpf, req.mother_name, req.samples.first.barcode ].each { |secret| expect(payloads).not_to include(secret) }
    expect(log).not_to include("123", req.samples.first.barcode)
  end

  it "médico só com ICP; um exame num item só; nenhum middleware simulado em produção" do
    doctor = lab_releaser!(provider, council: "CRM")
    expect(Lab::Release.call(requisition: req, item_ids: [ req.items.first.id ], signature: "advanced", totp: totp_for(doctor), by: doctor).reason)
      .to eq(:icp_required)
    expect(LabRequisitionItem.connection.indexes(:lab_requisition_items).find { |i| i.columns == [ "exam_order_id" ] }.unique).to be(true)
    expect(Platform::Features.find("fake_middleware", env: "production")).to be_nil
  end

  context "depois da liberação" do
    let!(:released) do
      hl7_post(oul("123", "I2"), token: token)
      release!(req.items.first.reload).payload[:report]
    end

    it "versão do exame, resultado e laudo nunca mudam nem somem (o banco recusa)" do
      item = req.items.first.reload
      result = LabResult.where(lab_requisition_item_id: item.id).first
      version = item.lab_exam_version
      expect(result).to be_present

      expect { version.update!(analysis_method: "Outro") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { version.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { result.update!(flag: "low") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { result.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { LabReport.find(released.id).update!(content: "{}") }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
      expect { LabReport.find(released.id).update!(status: "pending_signature") }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
      expect { LabReport.find(released.id).update!(status: "withdrawn") }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
      expect { LabReport.find(released.id).destroy! }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect { req.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { item.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect(released.reload.status).to eq("released")
    end

    it "laudo liberado tem data e PDF; devolvido não tem nenhum dos dois" do
      expect(released).to have_attributes(status: "released")
      expect([ released.released_at, released.pdf_file_id, released.pdf_sha256 ]).to all(be_present)
      sql = "UPDATE lab_reports SET released_at = NULL WHERE id = '#{released.id}'"
      expect { LabReport.transaction(requires_new: true) { LabReport.connection.execute(sql) } }
        .to raise_error(ActiveRecord::StatementInvalid, /refused|never changes/)
      expect(LabReport.where(status: "withdrawn").where.not(released_at: nil).or(LabReport.where(status: "withdrawn").where.not(pdf_file_id: nil))).to be_empty
    end

    it "um aviso por resultado crítico (índice único)" do
      expect(LabCriticalNotice.connection.indexes(:lab_critical_notices).find { |i| i.columns == [ "lab_result_id" ] }.unique).to be(true)
    end

    it "valor, mensagem HL7 e conteúdo do laudo ficam cifrados no banco" do
      raw_value = LabResult.connection.select_value("SELECT value FROM lab_results ORDER BY created_at LIMIT 1")
      expect(raw_value).not_to eq("123")
      expect(raw_value).not_to include("123 ")
      raw_hl7 = LabHl7Receipt.connection.select_value("SELECT raw FROM lab_hl7_receipts ORDER BY created_at LIMIT 1")
      expect(raw_hl7).to be_present
      expect(raw_hl7).not_to include("MSH|", req.samples.first.barcode)
      raw_content = LabReport.connection.select_value("SELECT content FROM lab_reports LIMIT 1")
      expect(raw_content).not_to include(req.patient.cpf.to_s)
      raw_mother = LabRequisition.connection.select_value("SELECT mother_name FROM lab_requisitions LIMIT 1")
      expect(raw_mother).not_to include(req.mother_name)
    end
  end

  it "um exame (exam_order) não entra em dois itens" do
    item = req.items.first
    other = LabSample.create!(lab_requisition: req, barcode: LabSample.barcode_for(req.number, 9), material: "Plasma", container: "Tubo")
    expect { LabRequisitionItem.create!(lab_requisition: req, exam_order_id: item.exam_order_id, lab_exam_version: item.lab_exam_version, lab_sample: other) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
