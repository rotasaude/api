# spec/models/sncr_tables_guard_spec.rb
require "rails_helper"

# ADR 0034 (Invariantes): o banco é a última palavra. Um número nasce free,
# passa a used com o documento e a voided depois; nunca volta, nunca muda de
# documento, nunca é apagado; (kind, number) único; o lote é só acréscimo.
RSpec.describe "Tabelas do estoque SNCR (triggers)" do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:user) { doctor!(unit) }
  # O número aponta para um documento de verdade (FK); os gatilhos rodam antes da FK.
  let(:document_id) { raw_document!(consultation: finalized_consultation!(unit: unit, doctor: user, citizen: verified_citizen!(1))).id }

  def refused(&) = ApplicationRecord.transaction(requires_new: true, &)

  def sql(statement) = ApplicationRecord.connection.execute(statement)

  def batch!(kind: "rce")
    SncrNumberBatch.create!(user: user, kind: kind, first_number: "2610.1-41.0000001", last_number: "2610.1-41.0000002",
                            quantity: 2, month: Date.current.beginning_of_month, month_request: 1, simulated: true,
                            requested_at: Time.current)
  end

  def number!(batch, value = "2610.1-41.0000001", kind: "rce")
    SncrNumber.create!(batch: batch, user: user, kind: kind, number: value, simulated: true)
  end

  it "free → used → voided; nunca volta, nunca troca de documento, nunca some" do
    number = number!(batch!)
    expect { refused { number.update!(status: "voided", voided_at: Time.current) } }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
    number.reload.update!(status: "used", document_id: document_id, used_at: Time.current)
    expect { refused { number.update!(document_id: SecureRandom.uuid) } }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
    expect { refused { number.reload.update!(status: "free", document_id: nil, used_at: nil) } }.to raise_error(ActiveRecord::StatementInvalid)
    # used → voided mantém o documento e a data de uso.
    other_document_id = raw_document!(consultation: finalized_consultation!(unit: unit, doctor: user, citizen: verified_citizen!(3))).id
    expect { refused { number.reload.update!(used_at: 1.day.ago) } }.to raise_error(ActiveRecord::StatementInvalid, /refused/)
    expect { refused { number.reload.update!(status: "voided", voided_at: Time.current, used_at: 1.day.ago) } }
      .to raise_error(ActiveRecord::StatementInvalid, /refused/)
    expect { refused { number.reload.update!(status: "voided", voided_at: Time.current, document_id: other_document_id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /refused/)
    number.reload.update!(status: "voided", voided_at: Time.current)
    expect { refused { number.reload.update!(status: "used", voided_at: nil) } }.to raise_error(ActiveRecord::StatementInvalid)
    expect { refused { number.reload.update_columns(number: "2610.1-41.0000009") } }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
    expect { refused { number.reload.destroy } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    expect { refused { sql("TRUNCATE sncr_numbers CASCADE") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "nasce free, sem documento; (kind, number) único; formato do número" do
    batch = batch!
    number!(batch)
    expect { refused { number!(batch) } }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(number!(batch!(kind: "ret"), kind: "ret")).to be_persisted # o mesmo texto noutro tipo é outro número
    expect { refused { SncrNumber.create!(batch: batch, user: user, kind: "rce", number: "2610.1-41.0000003", simulated: true, status: "used", document_id: document_id, used_at: Time.current) } }
      .to raise_error(ActiveRecord::StatementInvalid, /born free/)
    expect { refused { number!(batch, "12345") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_sncr_numbers_format/)
  end

  it "o número SNCR não aparece em inspect nem em pretty_print" do
    batch = batch!
    number = number!(batch)
    shown = [ number.inspect, number.pretty_inspect, batch.inspect, batch.pretty_inspect ].join
    expect(shown).not_to include("41.000000")
    expect(SncrNumber.filter_attributes.map(&:to_s)).to include("number")
    expect(SncrNumberBatch.filter_attributes.map(&:to_s)).to include("first_number", "last_number")
  end

  it "o lote é só acréscimo" do
    batch = batch!
    expect { refused { batch.update!(quantity: 3) } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { refused { batch.destroy } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "o motivo do papel é gravado, só no papel, com os valores do contrato, e nunca muda" do
    document = raw_document!(consultation: finalized_consultation!(unit: unit, doctor: user, citizen: verified_citizen!(2)))
    expect(document.paper_reason).to be_nil
    expect { refused { document.update_columns(paper_reason: "no_certificate") } }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
    attrs = document.attributes.except("id", "txid").merge("verification_token" => ClinicalDocuments::Codes.token,
                                                           "short_code" => ClinicalDocuments::Codes.short_code)
    expect { refused { ClinicalDocument.create!(attrs.merge("paper_reason" => "outro")) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_paper_reason/)
    expect { refused { ClinicalDocument.create!(attrs.merge("issue_mode" => "digital", "paper_reason" => "no_certificate")) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_paper_reason_mode/)
    expect(ClinicalDocument::PAPER_REASONS).to eq(%w[no_certificate signature_unavailable no_sncr_number nurse_antimicrobial feature_disabled])
  end

  it "o tipo novo de documento é sempre papel; o state aceita os propósitos do SNCR" do
    expect(ClinicalDocument::KINDS).to include("controlled_notification_record")
    consultation = finalized_consultation!(unit: unit, doctor: user, citizen: verified_citizen!(4))
    expect { refused { raw_document!(consultation: consultation, kind: "controlled_notification_record", issue_mode: "digital") } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_notification_paper/)
    expect(SignatureOauthState::PURPOSES).to include("sncr_rce", "sncr_ret")
    state = SignatureOauthState.create!(user: user, purpose: "sncr_rce", provider: "sncr_simulated", code_verifier: "v" * 43,
                                        return_to: "/dashboard/", expires_at: 10.minutes.from_now, created_at: Time.current)
    expect(state).to be_persisted
  end

  it "o endereço do prescritor é cifrado e o contato só existe completo" do
    professional = user.professional
    expect(professional.prescriber_contact).to be_nil
    prescriber_contact!(user)
    raw = ApplicationRecord.connection.select_value("SELECT prescriber_address FROM professionals WHERE id = #{ApplicationRecord.connection.quote(professional.id)}")
    expect(raw).not_to include("Araucárias")
    expect(professional.reload.prescriber_contact).to eq("address" => ControlledPrescriptionHelpers::ADDRESS, "phone" => "41999990000")
  end
end
