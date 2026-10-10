require "rails_helper"

# ADR 0033 (Invariantes): o banco é a última palavra. Documento emitido não
# muda (só issued → cancelled e a volta ao papel digital → paper, sem
# assinatura); itens da receita nascem com o documento; a lista de
# medicamentos só muda com evento da mesma transação; tudo só acréscimo; a
# re-cifra continua possível.
#
# Cada recusa roda num savepoint próprio (`refused`): sem ele o primeiro erro
# aborta a transação do exemplo e as recusas seguintes passariam por acidente
# (InFailedSqlTransaction também é StatementInvalid).
RSpec.describe "Tabelas dos documentos clínicos (triggers)" do
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def sql(statement) = ApplicationRecord.connection.execute(statement)
  def refused(&) = ApplicationRecord.transaction(requires_new: true, &)

  it "documento nasce emitido e só passa a cancelado, com motivo, data e usuário" do
    document = raw_document!(consultation: consultation)
    expect { refused { document.reload.update_columns(issue_mode: "digital") } }
      .to raise_error(ActiveRecord::StatementInvalid, /never changes/)
    expect { refused { document.reload.update!(content: { "type" => "leave", "days" => 9 }.to_json) } }
      .to raise_error(ActiveRecord::StatementInvalid, /never changes/)
    expect { refused { document.reload.update!(status: "cancelled") } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_cancellation/)
    document.reload.update!(status: "cancelled", cancel_reason: "Emitido para o paciente errado", cancelled_at: Time.current,
                            cancelled_by_user_id: doctor.id)
    expect { refused { document.reload.update!(status: "issued", cancel_reason: nil, cancelled_at: nil, cancelled_by_user_id: nil) } }
      .to raise_error(ActiveRecord::StatementInvalid, /never changes/)
    expect { refused { document.reload.destroy } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { refused { sql("TRUNCATE clinical_documents CASCADE") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { refused { raw_document!(consultation: consultation).tap { |d| d.update_columns(status: "cancelled") } } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_cancellation/)
    expect(document.reload).to be_cancelled
  end

  it "nasce emitido; documento de consulta exige CBO; fora da consulta só papel e só declaração" do
    source = raw_document!(consultation: consultation)
    cancelled = source.attributes.except("id", "txid").merge(
      "status" => "cancelled", "verification_token" => ClinicalDocuments::Codes.token,
      "short_code" => ClinicalDocuments::Codes.short_code, "cancel_reason" => "x" * 10, "cancelled_at" => Time.current,
      "cancelled_by_user_id" => doctor.id
    )
    expect { refused { ClinicalDocument.create!(cancelled) } }.to raise_error(ActiveRecord::StatementInvalid, /born issued/)
    attendance = consultation.attendance
    expect { refused { raw_document!(attendance: attendance, kind: "sick_note", author: verifier!) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_consultation/)
    expect { refused { raw_document!(attendance: attendance, kind: "attendance_declaration", issue_mode: "digital", author: verifier!) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_paper_outside_consultation/)
    expect { refused { ClinicalDocument.create!(source.attributes.except("id", "txid").merge("cbo_code" => nil, "verification_token" => ClinicalDocuments::Codes.token, "short_code" => ClinicalDocuments::Codes.short_code)) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_cbo_required/)
    expect(raw_document!(attendance: attendance, kind: "attendance_declaration", author: verifier!).cbo_code).to be_nil
  end

  it "volta ao papel: digital → paper sem assinatura; nunca paper → digital" do
    document = raw_document!(consultation: consultation, issue_mode: "digital")
    document.update!(issue_mode: "paper")
    expect { refused { document.reload.update!(issue_mode: "digital") } }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
    expect(document.reload.issue_mode).to eq("paper")
  end

  it "volta ao papel recusada quando já há assinatura gravada" do
    document = raw_document!(consultation: consultation, issue_mode: "digital")
    doctor.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF)
    request = SignatureRequest.create!(document_type: "ClinicalDocument", document_id: document.id,
                                       consultation_id: consultation.id, author_user_id: doctor.id)
    signature_row!(request, certificate: linked_certificate!(doctor))
    expect { refused { document.reload.update!(issue_mode: "paper") } }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
  end

  it "itens da receita nascem na transação do documento e nunca mudam" do
    item = ApplicationRecord.transaction do
      document = raw_document!(consultation: consultation, kind: "prescription", content: { "items" => [] })
      PrescriptionItem.create!(clinical_document: document, position: 1, free_text: "Chá de camomila",
                               printed_description: "Chá de camomila", quantity: 1, quantity_unit: "sachê",
                               route: "oral", dosage_instructions: "1 sachê à noite")
    end
    expect { refused { item.reload.update!(quantity: 2) } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { refused { item.reload.destroy } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "item de receita de documento de outra transação ou de outro tipo é recusado" do
    document = raw_document!(consultation: consultation, kind: "sick_note")
    expect do
      refused do
        PrescriptionItem.create!(clinical_document: document, position: 1, free_text: "x" * 3, printed_description: "x",
                                 quantity: 1, quantity_unit: "cp", route: "oral", dosage_instructions: "1 cp")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /born with their prescription/)
  end

  it "medicamento em uso só nasce e muda com evento da mesma transação" do
    expect do
      refused do
        PatientMedication.create!(patient: consultation.patient, free_text: "Chá", label: "Chá", status: "active", origin: "external")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /event of the same transaction/)
  end

  it "re-cifra: o conteúdo cifrado pode ser regravado sob a marca; nada mais" do
    document = raw_document!(consultation: consultation)
    CityEncryption.allowing_reencryption { document.update_columns(content: document.content) }
    expect(document.reload.content_data["days"]).to eq(1)
    expect { refused { document.reload.update_columns(content: document.content) } }
      .to raise_error(ActiveRecord::StatementInvalid, /never changes/)
  end

  it "protocolos e conferências são só acréscimo; itens nascem com a versão" do
    protocol = NursingProtocol.create!(title: "Saúde da mulher", number: "PE-01", year: 2026, created_by_user_id: doctor.id)
    version = NursingProtocolVersion.create!(nursing_protocol: protocol, version: 1, valid_from: Date.new(2026, 1, 1),
                                             created_by_user_id: doctor.id)
    NursingProtocolVersionItem.create!(nursing_protocol_version: version, catalog_item_id: SecureRandom.uuid)
    expect { refused { protocol.reload.update!(title: "Outro") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { refused { version.reload.update!(valid_until: Date.new(2026, 12, 31)) } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    lookup = DocumentVerificationLookup.create!(via: "short_code", outcome: "not_found")
    expect { refused { lookup.reload.destroy } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect(protocol.current_version(on: Date.new(2026, 10, 9))).to eq(version)
  end

  it "o pedido de assinatura aceita o documento clínico e o motivo document_cancelled" do
    document = raw_document!(consultation: consultation, issue_mode: "digital")
    request = SignatureRequest.create!(document_type: "ClinicalDocument", document_id: document.id,
                                       consultation_id: consultation.id, author_user_id: doctor.id)
    request.update!(status: "returned_to_paper", reason_code: "document_cancelled", resolved_at: Time.current)
    expect(SignatureRequest::REASONS).to include("document_cancelled")
  end
end
