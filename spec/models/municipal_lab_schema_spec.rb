require "rails_helper"

# ADR 0037 (Invariantes): versão, resultados, laudos e itens do laudo nunca
# mudam nem somem; o laudo só anda pending_signature → released|withdrawn e
# released → rectified; valores cifrados; um exame num item só; papéis novos.
RSpec.describe "Banco do laboratório municipal" do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:exam) { lab_exam!(provider: provider) }
  let(:version) { exam.current_version }

  it "versão do exame é imutável" do
    expect { version.update!(analysis_method: "Outro") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { version.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "resultado imutável e cifrado; inspect sem valor" do
    req = lab_requisition_row!(provider: provider, version: version)
    item = req.items.first
    result = LabResult.create!(lab_requisition_item: item, analyte_key: "glicose", value: "123", unit: "mg/dL", flag: "high",
                               source: "typed", entered_by_user: lab_staff!, entered_at: Time.current)
    raw = ApplicationRecord.connection.select_value("SELECT value FROM lab_results WHERE id = #{ApplicationRecord.connection.quote(result.id)}")
    expect(raw).not_to include("123")
    expect(result.inspect).not_to include("123")
    expect { result.update!(flag: "normal") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { LabRequisitionItem.create!(lab_requisition: req, exam_order_id: item.exam_order_id, lab_exam_version: version, lab_sample: item.lab_sample) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "laudo: só anda para a frente; conteúdo nunca muda; não some" do
    req = lab_requisition_row!(provider: provider, version: version)
    report = LabReport.create!(lab_requisition: req, exam_provider: provider, version: 1, partial: false, status: "pending_signature",
                               signature_kind: "icp", released_by_user: lab_releaser!(provider), content: { "a" => 1 }.to_json,
                               content_sha256: "a" * 64, verification_token: ClinicalDocuments::Codes.token,
                               short_code: ClinicalDocuments::Codes.short_code)
    expect { report.update!(content: "{}") }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
    report.reload # a gravação recusada deixa o conteúdo sujo na memória
    expect { report.update!(status: "rectified") }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
    file = pdf_file!(user: report.released_by_user).tap { |f| f.update!(consumed_at: Time.current) }
    report.update!(status: "released", released_at: Time.current, pdf_file_id: file.id, pdf_sha256: "b" * 64)
    expect { report.update!(status: "pending_signature") }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
    report.update!(status: "rectified")
    expect { report.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { req.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "papéis, número da requisição, código de barras e GAL uma vez" do
    user = staff_with("lab-#{SecureRandom.hex(3)}@cidade.gov.br", "lab_staff", "lab_releaser")
    expect(user.has_role?("lab_staff")).to be(true)
    expect(Membership::PRIVILEGED_ROLES).to include("lab_staff", "lab_releaser")
    first = LabRequisition.next_number
    expect(LabRequisition.next_number.to_i).to eq(first.to_i + 1)
    expect(first).to match(/\A\d{8}\z/)
    expect(LabSample.barcode_for("00000123", 1)).to eq("0000012301")
    order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: create_unit("UBS GAL"), requester: doctor!(create_unit("UBS D")))
    order.update!(gal_requisition: "2026-000123")
    expect { order.update!(gal_requisition: "outro") }.to raise_error(ActiveRecord::StatementInvalid, /recorded once/)
  end
end
