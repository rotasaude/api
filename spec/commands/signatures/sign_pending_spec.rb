# spec/commands/signatures/sign_pending_spec.rb
require "rails_helper"

# ADR 0032 (spec §5, finalização e regras; Review Focus 3): com sessão ativa,
# o job assina o JSON canônico (CAdES) e o PDF (PAdES) com UMA chamada ao PSC;
# sem sessão, certificado vencido/revogado/de outro CPF ou PSC/signer fora do
# ar, o pedido fica pending com o motivo (3 tentativas para o passageiro).
RSpec.describe Signatures::SignPending do
  before do
    Current.city = signature_city!
    ciap2_release!; cid10_release!; sigtap_release!
    stub_psc!
    @signer = stub_signer!
  end
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  let(:cpf) { SignatureHelpers::DOCTOR_CPF }
  let(:certificate) { linked_certificate!(doctor, leaf: fake_psc.leaf(cpf)) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def session!(**over) = signature_session!(doctor, certificate: certificate, token: fake_psc.token_for!(cpf: cpf), **over)
  def sign(request, **opts) = ApplicationRecord.transaction { described_class.call(request_id: request.id, **opts) }
  def psc_signature_calls(key = "vidaas") = fake_psc(key).log.count { |_verb, path| path == "/v0/oauth/signature" }
  # O PAdES do signer falso é o PDF + marcador + envelope: lê só o PDF.
  def pdf_text(bytes)
    bytes = bytes.b
    at = bytes.rindex(FakeSigner::MARKER)
    PDF::Reader.new(StringIO.new(at ? bytes[0...at] : bytes)).pages.map { |page| page.text.gsub(/\s+/, " ") }.join("\n")
  end

  it "assina a consulta: CAdES do JSON canônico e PAdES do PDF numa chamada ao PSC" do
    session!
    request = signature_request!(consultation, author: doctor)
    expect(sign(request)).to eq(:signed)
    request.reload
    signature = request.signature
    canonical = Signatures::Canonical.consultation(consultation)
    expect(request).to have_attributes(status: "signed", reason_code: nil)
    expect(request.resolved_at).to be_present
    expect(signature.canonical_json).to eq(canonical.json)
    expect(signature.canonical_sha256).to eq(canonical.sha256)
    expect(signature.signed_pdf_bytes).to start_with("%PDF")
    expect(signature.pdf_sha256).to eq(Digest::SHA256.hexdigest(signature.signed_pdf_bytes))
    expect(signature).to have_attributes(policy: "AD-RB", policy_oid: FakeSigner::POLICY_OID, last_verification: "valid",
                                         signer_cpf: cpf, signer_certificate_id: certificate.id)
    expect(signature.material.keys).to match_array(%w[cades pades])
    expect(psc_signature_calls).to eq(1)
    expect(DomainEvent.where(name: "signature.signed").sole.payload)
      .to eq("signature_id" => signature.id, "request_id" => request.id, "document_type" => "consultation",
             "document_id" => consultation.id)
  end

  it "grava o provider do certificado; PSC real: rodapé sem o aviso de simulada" do
    session!
    request = signature_request!(consultation, author: doctor)
    expect(sign(request)).to eq(:signed)
    signature = request.reload.signature
    expect([ signature.provider, signature.simulated? ]).to eq([ "vidaas", false ])
    text = pdf_text(signature.signed_pdf_bytes)
    expect(text).to include("Documento assinado digitalmente por")
    expect(text.downcase).not_to include("simulada")
  end

  it "assina o adendo com o JSON do adendo (cadeia) e o PDF só dele" do
    session!
    addendum = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame adicional pedido",
                                               text: "Pedido creatinina").payload[:addendum]
    request = signature_request!(addendum, author: doctor)
    expect(sign(request)).to eq(:signed)
    expect(JSON.parse(request.reload.signature.canonical_json).dig("addendum", "previous_sha256"))
      .to eq(Signatures::Canonical.consultation(consultation).sha256)
  end

  it "sem sessão: no_session; sessão vencida: session_expired; certificado vencido: certificate_expired" do
    request = signature_request!(consultation, author: doctor)
    certificate
    expect(sign(request)).to eq(:pending)
    expect(request.reload.reason_code).to eq("no_session")
    started = 13.hours.ago
    session!(started_at: started, expires_at: started + 12.hours) # já vencida, dentro do limite de 12 h
    expect(sign(request)).to eq(:pending)
    expect(request.reload.reason_code).to eq("session_expired")

    other = signature_request!(finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2)), author: doctor)
    certificate.update!(not_after: 1.minute.ago)
    expect(sign(other)).to eq(:pending)
    expect([ other.reload.reason_code, certificate.reload.status ]).to eq(%w[certificate_expired expired])
    expect(psc_signature_calls).to eq(0)
    expect(DomainEvent.where(name: "signature.failed").pluck(:payload).map { |payload| payload.keys.sort }.uniq).to eq([ %w[reason_code request_id] ])
  end

  it "tentativas: PSC e signer fora do ar → retry, retry, pending com o motivo (Review Focus 3)" do
    session!
    request = signature_request!(consultation, author: doctor)
    fake_psc.failures.push(503, :refused, 503)
    expect([ sign(request), sign(request), sign(request) ]).to eq(%i[retry retry pending])
    expect(request.reload).to have_attributes(status: "pending", reason_code: "provider_unavailable", attempts: 3)

    other = signature_request!(finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2)), author: doctor)
    @signer.unavailable = true
    expect(sign(other)).to eq(:retry)
    expect(other.reload.reason_code).to eq("signer_unavailable")
    @signer.unavailable = false
    expect(sign(other)).to eq(:signed)
  end

  it "token recusado pelo PSC: a sessão cai e o pedido fica session_expired" do
    session = session!
    request = signature_request!(consultation, author: doctor)
    fake_psc.expire_tokens!
    expect(sign(request)).to eq(:pending)
    expect([ request.reload.reason_code, session.reload.status ]).to eq(%w[session_expired expired])
  end

  it "revogado (422 invalid_certificate no /prepare, R9): certificate_revoked, sem tentativa, nada gravado, certificado marcado" do
    session!
    request = signature_request!(consultation, author: doctor)
    @signer.revoked_serials << certificate.serial_number
    expect(sign(request)).to eq(:pending)
    expect([ request.reload.reason_code, request.attempts, certificate.reload.status, Signature.count ])
      .to eq([ "certificate_revoked", 0, "revoked", 0 ])
    expect(@signer.calls.count(:check)).to eq(1)
    expect(psc_signature_calls).to eq(0)
  end

  it "R9: invalid_certificate e o signer diz vencido → certificate_expired (certificado marcado), sem tentativa" do
    session!
    request = signature_request!(consultation, author: doctor)
    allow(@signer).to receive(:prepare).and_raise(Signatures::Signer::Rejected, "invalid_certificate")
    allow(@signer).to receive(:check_certificate).and_return(
      Signatures::Signer::CertificateCheck.new(status: "invalid", signer_cpf: cpf, not_after: 1.day.ago, reasons: %w[certificate_expired])
    )
    expect(sign(request)).to eq(:pending)
    expect([ request.reload.reason_code, request.attempts, certificate.reload.status ]).to eq([ "certificate_expired", 0, "expired" ])
    expect(@signer).to have_received(:check_certificate).once
  end

  it "R9: invalid_certificate por outro motivo (cadeia não confiável) → verification_failed definitivo" do
    session!
    request = signature_request!(consultation, author: doctor)
    @signer.untrusted_serials << certificate.serial_number
    expect(sign(request)).to eq(:pending)
    expect([ request.reload.reason_code, request.attempts, certificate.reload.status ]).to eq([ "verification_failed", 0, "active" ])
    expect(psc_signature_calls).to eq(0)
  end

  it "R9: invalid_certificate que a consulta diz valid → verification_failed passageiro" do
    session!
    request = signature_request!(consultation, author: doctor)
    allow(@signer).to receive(:prepare).and_raise(Signatures::Signer::Rejected, "invalid_certificate")
    expect(sign(request)).to eq(:retry)
    expect(request.reload).to have_attributes(reason_code: "verification_failed", attempts: 1)
  end

  it "documento que não se monta (inexistente) → verification_failed definitivo, sem tentativa" do
    session!
    request = signature_request!(author: doctor)
    expect(sign(request)).to eq(:pending)
    expect(request.reload).to have_attributes(status: "pending", reason_code: "verification_failed", attempts: 0)
    expect(psc_signature_calls).to eq(0)
  end

  it "sessão aberta com outro certificado (anterior) não serve: no_session" do
    old = linked_certificate!(doctor, status: "replaced", leaf: fake_psc.leaf(cpf))
    signature_session!(doctor, certificate: old, token: fake_psc.token_for!(cpf: cpf))
    certificate
    request = signature_request!(consultation, author: doctor)
    expect(sign(request)).to eq(:pending)
    expect(request.reload.reason_code).to eq("no_session")
    expect(psc_signature_calls).to eq(0)
  end

  it "R9: 400 invalid_request no /prepare (estado > 32 MiB) → verification_failed sem tentar de novo" do
    session!
    request = signature_request!(consultation, author: doctor)
    allow(@signer).to receive(:prepare).and_raise(Signatures::Signer::Rejected, "invalid_request")
    expect(sign(request)).to eq(:pending)
    expect(request.reload).to have_attributes(status: "pending", reason_code: "verification_failed", attempts: 0)
    expect(psc_signature_calls).to eq(0)
  end

  it "R9: 500 no /prepare (LCR fora do ar) → signer_unavailable passageiro" do
    session!
    request = signature_request!(consultation, author: doctor)
    @signer.revocation_unavailable = true
    expect(sign(request)).to eq(:retry)
    expect(request.reload).to have_attributes(reason_code: "signer_unavailable", attempts: 1)
    expect(psc_signature_calls).to eq(0)
  end

  it "CPF do profissional diferente do certificado (NGS2.01.02): certificate_cpf_mismatch" do
    session!
    request = signature_request!(consultation, author: doctor)
    doctor.professional.update!(cpf: SignatureHelpers::OTHER_CPF)
    expect(sign(request)).to eq(:pending)
    expect(request.reload.reason_code).to eq("certificate_cpf_mismatch")
    expect(psc_signature_calls).to eq(0)
  end

  it "interruptor desligado: volta ao papel com feature_disabled; resolvido: skipped" do
    session!
    request = signature_request!(consultation, author: doctor)
    signature_city!(enabled: false)
    expect(sign(request)).to eq(:returned_to_paper)
    expect(request.reload).to have_attributes(status: "returned_to_paper", reason_code: "feature_disabled")
    expect(DomainEvent.where(name: "signature.returned_to_paper").sole.payload).to eq("request_id" => request.id, "reason_code" => "feature_disabled")
    expect(sign(request)).to eq(:skipped)
  end

  it "consulta e adendo no mesmo Signing: o adendo falha no preparo (400) e a consulta assina mesmo assim" do
    session!
    addendum = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame adicional pedido",
                                               text: "Pedido creatinina").payload[:addendum]
    requests = [ signature_request!(addendum, author: doctor), signature_request!(consultation, author: doctor) ]
    real_prepare = @signer.method(:prepare)
    allow(@signer).to receive(:prepare) do |kind:, document:, certificate_der:|
      if kind == "cades" && JSON.parse(document).key?("addendum")
        raise Signatures::Signer::Rejected, "invalid_request"
      end

      real_prepare.call(kind: kind, document: document, certificate_der: certificate_der)
    end
    outcome = ApplicationRecord.transaction do
      Signatures::Signing.call(requests: requests, access_token: SignatureSession.usable_for(doctor.id).access_token,
                               certificate: certificate, signer: @signer)
    end
    expect(outcome.signed.map(&:signature_request_id)).to eq([ requests.last.id ])
    expect(outcome.failed).to eq([ [ requests.first, "verification_failed" ] ])
    expect(outcome.final).to eq([ requests.first.id ])
  end

  it "trava o pedido com FOR UPDATE SKIP LOCKED (Review Focus 1)" do
    request = signature_request!(consultation, author: doctor)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { sign(request) }
    expect(sql.grep(/signature_requests/).first).to match(/FOR UPDATE SKIP LOCKED/)
  end

  it "nada de token, CPF ou texto clínico no log, sucesso ou falha" do
    session!
    request = signature_request!(consultation, author: doctor)
    other = signature_request!(finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2)), author: doctor)
    token = SignatureSession.usable_for(doctor.id).access_token
    log = capture_log do
      sign(request)
      @signer.revoked_serials << certificate.serial_number
      sign(other)
    end
    expect(log).not_to include(token)
    expect(log).not_to include(cpf)
    expect(log).not_to include(draft_body["subjective"])
    expect(log).not_to include(draft_body["plan"])
  end

  context "PSC simulado (ADR 0032, revisão)" do
    before { stub_psc_mock! }

    let(:certificate) { linked_certificate!(doctor, provider: "simulated", leaf: fake_psc("simulated").leaf(cpf)) }

    def session! = signature_session!(doctor, certificate: certificate, token: fake_psc("simulated").token_for!(cpf: cpf))

    it "fora de produção assina e marca: provider simulated e o aviso em toda página do PDF" do
      session!
      request = signature_request!(consultation, author: doctor)
      expect(sign(request)).to eq(:signed)
      signature = request.reload.signature
      expect([ signature.provider, signature.simulated? ]).to eq([ "simulated", true ])
      expect(psc_signature_calls("simulated")).to eq(1)
      bytes = signature.signed_pdf_bytes.b
      pages = PDF::Reader.new(StringIO.new(bytes[0...bytes.rindex(FakeSigner::MARKER)])).pages
      expect(pages.map { |page| page.text.gsub(/\s+/, " ") }).to all(include("Assinatura simulada — sem validade jurídica"))
    end

    it "invariante: em produção recusa o certificado simulado e não grava nada (provider_unavailable, sem tentativa)" do
      session!
      request = signature_request!(consultation, author: doctor)
      expect(sign(request, env: "production")).to eq(:pending)
      expect(request.reload).to have_attributes(status: "pending", reason_code: "provider_unavailable", attempts: 0)
      expect(Signature.where(provider: "simulated").count).to eq(0)
      expect(psc_signature_calls("simulated")).to eq(0)
      expect(@signer.calls).to be_empty
    end

    it "invariante direto no Signing: em produção nenhum pedido assinado" do
      session!
      request = signature_request!(consultation, author: doctor)
      outcome = ApplicationRecord.transaction do
        Signatures::Signing.call(requests: [ request ], access_token: "x", certificate: certificate, signer: @signer, env: "production")
      end
      expect(outcome.signed).to be_empty
      expect(outcome.failed).to eq([ [ request, "provider_unavailable" ] ])
      expect(outcome.final).to eq([ request.id ])
      expect(Signature.count).to eq(0)
    end
  end
end
