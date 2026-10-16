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
    order.reload
    expect { order.update!(gal_requisition: nil) }.to raise_error(ActiveRecord::StatementInvalid, /recorded once/)
  end

  # Mutação: tirar uma chave do filtro do 21b (ou ancorar errado) põe dado do
  # paciente em claro no "Parameters:" do log.
  it "o log de parâmetros esconde os dados do laboratório, só nas chaves exatas" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    keys = %w[mother_name clinical_info delivered_to notified_person contacts totp restriction_note gal_requisition barcode barcodes number]
    expect(filter.filter(keys.index_with { "x" })).to eq(keys.index_with { "[FILTERED]" })
    expect(filter.filter("address_number" => "12", "sigtap_code" => "0202010473"))
      .to eq("address_number" => "12", "sigtap_code" => "0202010473")
  end

  describe "laudo: transições e retificação" do
    let(:req) { lab_requisition_row!(provider: provider, version: version) }
    let(:releaser) { lab_releaser!(provider) }

    def report!(number, replaces: nil, token: ClinicalDocuments::Codes.token)
      LabReport.create!(lab_requisition: req, exam_provider: provider, version: number, partial: false, status: "pending_signature",
                        signature_kind: "icp", released_by_user: releaser, content: { "v" => number }.to_json,
                        content_sha256: "a" * 64, verification_token: token, short_code: ClinicalDocuments::Codes.short_code,
                        replaces_report: replaces, rectification_reason: replaces && "valor digitado errado")
    end

    def release!(report)
      file = pdf_file!(user: releaser).tap { |f| f.update!(consumed_at: Time.current) }
      report.update!(status: "released", released_at: Time.current, pdf_file_id: file.id, pdf_sha256: "b" * 64)
    end

    it "pending_signature → withdrawn; withdrawn não sai mais do lugar" do
      report = report!(1)
      report.update!(status: "withdrawn")
      %w[released pending_signature rectified].each do |status|
        expect { report.update!(status: status) }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
        report.reload
      end
    end

    # Notas #5 (Tasks 17/18): toque sem mudar a situação é recusado; withdrawn
    # nunca ganha liberação nem PDF; released nasce com os três.
    it "pending_signature: toque recusado; withdrawn sem liberação nem PDF; released com data, PDF e hash" do
      report = report!(1)
      expect { report.touch }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
      report.reload
      file = pdf_file!(user: releaser).tap { |f| f.update!(consumed_at: Time.current) }
      expect { report.update!(status: "withdrawn", released_at: Time.current) }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
      report.reload
      expect { report.update!(status: "withdrawn", pdf_file_id: file.id, pdf_sha256: "b" * 64) }
        .to raise_error(ActiveRecord::StatementInvalid, /refused/)
      report.reload
      expect { report.update!(status: "released", released_at: Time.current) }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
      report.reload
      report.update!(status: "withdrawn")
      expect(report.reload).to have_attributes(status: "withdrawn", released_at: nil, pdf_file_id: nil, pdf_sha256: nil)
    end

    it "released → rectified não troca o PDF" do
      report = report!(1)
      release!(report)
      expect { report.update!(status: "rectified", pdf_sha256: "c" * 64) }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
      report.reload
      expect { report.update!(status: "rectified", released_at: 1.day.ago) }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
      report.reload
      report.update!(status: "rectified")
      expect(report.reload.status).to eq("rectified")
    end

    it "retificação retirada (ICP devolvido) não impede outra retificação do mesmo original; duas vivas, sim" do
      original = report!(1)
      release!(original)
      report!(2, replaces: original).update!(status: "withdrawn")
      expect { report!(3, replaces: original) }.not_to raise_error
      expect { report!(4, replaces: original) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "token de conferência no formato do /v (22 caracteres base64url)" do
      expect { report!(1, token: "curto") }.to raise_error(ActiveRecord::StatementInvalid, /ck_lab_reports_token/)
      expect { report!(1, token: "#{'a' * 21}!") }.to raise_error(ActiveRecord::StatementInvalid, /ck_lab_reports_token/)
    end

    it "a requisição não tem índice próprio em lab_reports (idx_lab_reports_version o cobre)" do
      names = ApplicationRecord.connection.indexes(:lab_reports).map(&:name)
      expect(names).to include("idx_lab_reports_version")
      expect(names).not_to include("index_lab_reports_on_lab_requisition_id")
    end
  end

  describe "recibos, avisos e o que nunca some" do
    let(:req) { lab_requisition_row!(provider: provider, version: version) }

    def receipt!
      token = LabMiddlewareToken.create!(exam_provider: provider, token_digest: LabMiddlewareToken.digest(SecureRandom.hex(20)))
      LabHl7Receipt.create!(lab_middleware_token: token, control_id: SecureRandom.hex(4), message_type: "OUL^R22", raw: "MSH|1")
    end

    it "recibo HL7: o bruto só pode ser purgado (NULL); nada mais muda e não some" do
      receipt = receipt!
      expect { receipt.update!(raw: "MSH|2") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      receipt.reload
      expect { receipt.update!(control_id: "outro") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      receipt.reload
      expect { receipt.update!(control_id: "outro", raw: nil) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      receipt.reload
      receipt.update!(raw: nil)
      expect(receipt.reload.raw).to be_nil
      expect { receipt.update!(raw: "MSH|3") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { receipt.reload.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    end

    it "aviso de crítico é imutável" do
      result = LabResult.create!(lab_requisition_item: req.items.first, analyte_key: "glicose", value: "450", unit: "mg/dL",
                                 flag: "critical_high", source: "typed", entered_by_user: lab_staff!, entered_at: Time.current)
      notice = LabCriticalNotice.create!(lab_result: result, notified_person: "Dra. Ana", notified_role: "médica", channel: "telefone",
                                         notified_at: Time.current, recorded_by_user: lab_staff!)
      expect { notice.update!(notified_role: "enfermeira") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      notice.reload
      expect { notice.update!(notified_person: "Outra") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { notice.reload.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    end

    it "amostra, remessa e item nunca são apagados; TRUNCATE recusado" do
      item = req.items.first
      shipment = LabShipment.create!(origin_unit: req.origin_unit, exam_provider: provider, temperature_celsius: 4.5,
                                     created_by_user: lab_staff!)
      # delete não abre savepoint: sem ele, a 1ª recusa aborta a transação do exemplo.
      savepoint = ->(&blk) { ApplicationRecord.transaction(requires_new: true, &blk) }
      expect { savepoint.call { item.delete } }.to raise_error(ActiveRecord::StatementInvalid, /lab_requisition_items is append-only: DELETE refused/)
      expect { savepoint.call { item.lab_sample.delete } }.to raise_error(ActiveRecord::StatementInvalid, /lab_samples is append-only: DELETE refused/)
      expect { savepoint.call { shipment.delete } }.to raise_error(ActiveRecord::StatementInvalid, /lab_shipments is append-only: DELETE refused/)
      expect { savepoint.call { ApplicationRecord.connection.execute("TRUNCATE lab_shipments CASCADE") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: TRUNCATE refused/)
    end
  end
end
