# spec/models/signature_tables_guard_spec.rb
require "rails_helper"

# ADR 0032 (spec §4; invariantes): um certificado e uma sessão ativos por
# usuário; um pedido por documento; uma assinatura por pedido e por documento;
# assinatura gravada não muda (só a validação e a re-cifra); pedido resolvido
# não volta; segredos e documento cifrados com a chave da cidade.
RSpec.describe "Tabelas da assinatura digital" do
  before { Current.city = signature_city! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  let(:certificate) { linked_certificate!(doctor) }

  def raw(table, column, id)
    ApplicationRecord.connection.select_value("SELECT #{column} FROM #{table} WHERE id = #{ApplicationRecord.connection.quote(id)}")
  end

  describe "signer_certificates e signature_sessions" do
    it "um ativo por usuário; o CPF e o certificado ficam cifrados" do
      certificate
      expect { attempt { linked_certificate!(doctor) } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { attempt { linked_certificate!(doctor, status: "replaced") } }.not_to raise_error
      expect(raw("signer_certificates", "subject_cpf", certificate.id)).not_to include(SignatureHelpers::DOCTOR_CPF)
      expect(certificate.reload.info.cpf).to eq(SignatureHelpers::DOCTOR_CPF)
      expect(certificate.inspect).not_to include(SignatureHelpers::DOCTOR_CPF)
    end

    it "uma sessão ativa por usuário; até 12 h; o token fica cifrado e fora do inspect" do
      session = signature_session!(doctor, certificate: certificate, token: "TOKEN-MARCADOR")
      expect { attempt { signature_session!(doctor, certificate: certificate) } }.to raise_error(ActiveRecord::RecordNotUnique)
      session.update!(status: "revoked")
      expect { attempt { signature_session!(doctor, certificate: certificate, expires_at: 13.hours.from_now) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_signature_sessions_lifetime/)
      expect(raw("signature_sessions", "access_token", session.id)).not_to include("TOKEN-MARCADOR")
      expect(session.inspect).not_to include("TOKEN-MARCADOR")
    end
  end

  describe "signature_requests" do
    it "um por documento; identidade fixa; nunca some; resolvido não volta" do
      request = signature_request!(author: doctor)
      dup = request.attributes.slice("document_type", "document_id", "consultation_id", "author_user_id")
      expect { attempt { SignatureRequest.create!(dup) } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { attempt { request.update_columns(author_user_id: verifier!.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      expect { attempt { request.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      request.update!(reason_code: "no_session", attempts: 1)
      request.update!(status: "returned_to_paper", reason_code: "user_request", return_note: "sem certificado hoje", resolved_at: Time.current)
      expect { attempt { request.update!(status: "pending", resolved_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /resolved signature request never changes/)
      expect(raw("signature_requests", "return_note", request.id)).not_to include("sem certificado")
    end

    it "CHECKs: motivo do catálogo; resolvido exige resolved_at; nota só na volta ao papel" do
      doctor # fora do savepoint: o primeiro attempt desfaria o usuário
      expect { attempt { signature_request!(author: doctor, reason_code: "porque_sim") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_signature_requests_reason/)
      expect { attempt { SignatureRequest.create!(document_type: "Consultation", document_id: SecureRandom.uuid, consultation_id: SecureRandom.uuid, author_user_id: doctor.id, status: "signed") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_signature_requests_resolution/)
      expect { attempt { signature_request!(author: doctor).update!(return_note: "nota fora de hora") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_signature_requests_return_note/)
    end
  end

  describe "signatures" do
    let(:request) { signature_request!(author: doctor) }

    it "uma por pedido e por documento; conteúdo nunca muda; validação muda; não some" do
      signature = signature_row!(request, certificate: certificate, canonical_json: "{\"MARCADOR\":1}")
      expect { attempt { signature_row!(request, certificate: certificate) } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { attempt { signature.update!(policy: "AD-RT") } }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
      expect { attempt { signature.update!(canonical_json: "{}") } }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
      expect { attempt { signature.update_columns(provider: "simulated") } }.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
      signature.reload # descarta o que os attempts recusados deixaram sujo em memória
      expect { signature.update!(last_verification: "indeterminate", last_verification_at: Time.current, last_verification_reasons: [ "crl_unavailable" ]) }
        .not_to raise_error
      expect { attempt { signature.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect { attempt { ApplicationRecord.connection.execute("TRUNCATE signatures CASCADE") } }.to raise_error(ActiveRecord::StatementInvalid)
      expect(raw("signatures", "canonical_json", signature.id)).not_to include("MARCADOR")
    end

    it "re-cifra de assinatura gravada: só as colunas cifradas, conteúdo idêntico (Review Focus 2)" do
      signature = signature_row!(request, certificate: certificate, canonical_json: "{\"MARCADOR\":1}")
      before = raw("signatures", "canonical_json", signature.id)
      expect { CityEncryption.allowing_reencryption { signature.encrypt } }.not_to raise_error
      expect { CityEncryption.allowing_reencryption { certificate.encrypt } }.not_to raise_error
      request.update!(status: "returned_to_paper", reason_code: "user_request", return_note: "devolvido ao papel", resolved_at: Time.current)
      expect { CityEncryption.allowing_reencryption { request.encrypt } }.not_to raise_error
      reloaded = signature.reload
      expect(raw("signatures", "canonical_json", signature.id)).not_to eq(before)
      expect(Digest::SHA256.hexdigest(reloaded.canonical_json)).to eq(signature.canonical_sha256)
      expect do
        attempt do
          ApplicationRecord.connection.execute("SET LOCAL rota.reencrypting = 'on'")
          signature.update_columns(policy_oid: "1.2.3")
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /never changes/)
    end
  end

  describe "provedor simulado (signature_psc_mock)" do
    it "os CHECKs aceitam os cinco PSCs reais e o simulado, e nada mais" do
      expect(SignerCertificate::PROVIDERS).to eq(SignerCertificate::REAL_PROVIDERS + [ "simulated" ])
      expect(SignerCertificate::REAL_PROVIDERS).to eq(%w[vidaas birdid safeid neoid remoteid])
      simulated = linked_certificate!(doctor, provider: "simulated")
      session = signature_session!(doctor, certificate: simulated)
      signature = signature_row!(signature_request!(author: doctor), certificate: simulated)
      expect([ session.provider, signature.reload.provider ]).to eq(%w[simulated simulated])
      expect(signature).to be_simulated
      SignatureOauthState.create!(user: doctor, purpose: "link", provider: "simulated", code_verifier: "v" * 43,
                                  expires_at: 10.minutes.from_now, created_at: Time.current)
      expect { attempt { simulated.update_columns(provider: "falso") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_signer_certificates_provider/)
      expect { attempt { session.update_columns(provider: "falso") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_signature_sessions_provider/)
      expect { attempt { SignatureOauthState.create!(user: doctor, purpose: "link", provider: "falso", code_verifier: "v" * 43, expires_at: 10.minutes.from_now) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_signature_oauth_states_provider/)
      other = signature_request!(author: doctor)
      stray = Signature.new(signature.attributes.except("id", "created_at")
                                     .merge("signature_request_id" => other.id, "document_id" => other.document_id, "provider" => "falso"))
      expect { attempt { stray.save!(validate: false) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_signatures_provider/)
    end

    it "o médico que assina tem MFA cadastrado (step-up possível)" do
      expect(doctor).to be_mfa_enrolled
    end
  end

  it "todo atributo cifrado novo está na lista da re-cifra" do
    expect(CityEncryption::CITY_KEYED_TARGETS).to include(
      [ SignerCertificate, :subject_cpf ], [ SignerCertificate, :certificate_der ], [ SignatureSession, :access_token ],
      [ SignatureOauthState, :code_verifier ], [ SignatureRequest, :return_note ], [ Signature, :canonical_json ],
      [ Signature, :cades ], [ Signature, :signed_pdf ], [ Signature, :validation_material ], [ Signature, :signer_cpf ]
    )
  end
end
