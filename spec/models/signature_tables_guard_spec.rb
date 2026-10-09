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
      expect { attempt { ApplicationRecord.connection.execute("TRUNCATE signature_requests CASCADE") } }
        .to raise_error(ActiveRecord::StatementInvalid, /signature_requests is append-only: TRUNCATE refused/)
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
      expect { attempt { ApplicationRecord.connection.execute("TRUNCATE signatures") } }
        .to raise_error(ActiveRecord::StatementInvalid, /signatures is append-only: TRUNCATE refused/)
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

  # Review Focus 2: a rotação de chave da cidade (o código real, não só
  # record.encrypt) regrava o que a assinatura cifrou sem esbarrar na
  # imutabilidade, e o conteúdo assinado continua idêntico byte a byte.
  describe "rotação de chave com assinatura gravada" do
    let(:old_material) { "0" * 64 }
    let(:city) { Current.city }

    def in_city(&) = CityConnection.with(city) { Current.set(city: city, &) }

    # Material arbitrário (a chave "antiga"), como em spec/commands/clinical_record_reencryption_spec.rb.
    def with_material(material, &block)
      other = City.new(slug: city.slug, name: city.name, status: city.status,
                       database_url: city.database_url, encryption_key: material)
      CityConnection.with(city) do
        Current.set(city: other) do
          ActiveRecord::Encryption.with_encryption_context(**CityEncryption.context_properties(other), &block)
        end
      end
    end

    def call_job_body(**kwargs)
      ReencryptionJob.instance_method(:perform).super_method.bind_call(ReencryptionJob.new, **kwargs)
    end

    # Assinatura gravada (pedido signed), pedido devolvido ao papel com nota,
    # sessão e state do OAuth.
    def signature_rows!
      doctor = signer_doctor!(create_unit)
      certificate = linked_certificate!(doctor)
      session = signature_session!(doctor, certificate: certificate, token: "TOKEN-DA-SESSAO")
      oauth = SignatureOauthState.create!(user: doctor, purpose: "link", provider: "vidaas", code_verifier: "verificador-pkce-#{'x' * 30}",
                                          expires_at: 10.minutes.from_now, created_at: Time.current)
      signed = signature_request!(author: doctor)
      signature = signature_row!(signed, certificate: certificate, canonical_json: "{\"MARCADOR\":1}")
      signed.update!(status: "signed", resolved_at: Time.current)
      returned = signature_request!(author: doctor)
      returned.update!(status: "returned_to_paper", reason_code: "user_request", return_note: "devolvido ao papel hoje",
                       resolved_at: Time.current)
      { certificate: certificate.id, session: session.id, oauth: oauth.id, signed: signed.id, signature: signature.id,
        returned: returned.id }
    end

    def plaintexts(rows)
      signature = Signature.find(rows[:signature])
      certificate = SignerCertificate.find(rows[:certificate])
      signature.slice(:canonical_json, :cades, :signed_pdf, :validation_material, :signer_cpf, :canonical_sha256, :pdf_sha256)
               .merge("certificate_der" => certificate.certificate_der, "subject_cpf" => certificate.subject_cpf,
                      "return_note" => SignatureRequest.find(rows[:returned]).return_note,
                      "access_token" => SignatureSession.find(rows[:session]).access_token,
                      "code_verifier" => SignatureOauthState.find(rows[:oauth]).code_verifier)
    end

    def expect_intact(rows, expected)
      expect(plaintexts(rows)).to eq(expected)
      signature = Signature.find(rows[:signature])
      expect(Digest::SHA256.hexdigest(signature.canonical_json)).to eq(signature.canonical_sha256)
      expect(Digest::SHA256.hexdigest(signature.signed_pdf_bytes)).to eq(signature.pdf_sha256)
      expect(Signature.where(signer_cpf: SignatureHelpers::DOCTOR_CPF).pluck(:id)).to eq([ rows[:signature] ])
      expect(SignerCertificate.where(subject_cpf: SignatureHelpers::DOCTOR_CPF).pluck(:id)).to eq([ rows[:certificate] ])
      expect(ApplicationRecord.connection.select_value("SELECT current_setting('rota.reencrypting', true)")).not_to eq("on")
      expect { attempt { signature.update_columns(policy_oid: "1.2.3") } }
        .to raise_error(ActiveRecord::StatementInvalid, /never changes/)
      expect { attempt { signature.update_columns(canonical_json: "{}") } }
        .to raise_error(ActiveRecord::StatementInvalid, /never changes/)
      expect { attempt { SignatureRequest.find(rows[:returned]).update_columns(return_note: "outra nota qualquer") } }
        .to raise_error(ActiveRecord::StatementInvalid, /resolved signature request never changes/)
      expect { attempt { SignatureRequest.find(rows[:signed]).update_columns(status: "pending", resolved_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /resolved signature request never changes/)
    end

    it "ReencryptionJob (chave atual): regrava sob a marca, conteúdo idêntico, imutabilidade de volta" do
      rows = in_city { signature_rows! }
      expected = in_city { plaintexts(rows) }
      before = in_city { raw("signatures", "canonical_json", rows[:signature]) }

      stats = in_city { call_job_body(only: %i[signer_certificate signature_session signature_oauth_state signature_request signature]) }

      expect(stats).to include("SignerCertificate" => 1, "SignatureSession" => 1, "SignatureOauthState" => 1,
                               "SignatureRequest" => 1, "Signature" => 1)
      in_city do
        expect(raw("signatures", "canonical_json", rows[:signature])).not_to eq(before)
        expect_intact(rows, expected)
      end
    end

    it "CityRekey (material antigo → material da cidade): legível com a nova, ilegível com a antiga" do
      rows = with_material(old_material) { signature_rows! }
      expected = with_material(old_material) { plaintexts(rows) }

      result = CityRekey.call(city: city, from_key: old_material)

      expect(result).to be_ok
      expect(result.payload[:counts]).to include("SignerCertificate" => 2, "SignatureSession" => 1, "SignatureOauthState" => 1,
                                                 "SignatureRequest" => 1, "Signature" => 5)
      in_city { expect_intact(rows, expected) }
      with_material(old_material) do
        expect { Signature.find(rows[:signature]).canonical_json }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
        expect { SignatureSession.find(rows[:session]).access_token }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
        expect { SignatureRequest.find(rows[:returned]).return_note }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
        expect(Signature.where(signer_cpf: SignatureHelpers::DOCTOR_CPF).count).to eq(0)
      end
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
