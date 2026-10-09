# app/services/signatures/signing.rb
# O ato de assinar (ADR 0032; spec §5, §7): para cada pedido, prepara o CAdES
# do JSON canônico e o PAdES do PDF no signer; pede ao PSC UMA assinatura RAW
# de todos os hashes (sessão do turno ou token do lote); monta, verifica (antes
# de gravar, NGS2.03.01) e grava num savepoint por pedido. Chame dentro da
# transação da cidade, com os pedidos travados. Erros do PSC e indisponibilidade
# do signer ANTES do PSC sobem para quem chama (job ou lote decidem a tentativa).
#
# R9 (signer real): certificado revogado/de cadeia não confiável é 422
# invalid_certificate no /prepare → uma consulta a /certificates/check decide o
# motivo (certificate_revoked | certificate_expired | verification_failed) e
# vale para todos os pedidos do lote; 400 no /prepare (ex.: estado > 32 MiB) é
# verification_failed DEFINITIVO (sem novas tentativas: `final`).
#
# ADR 0032 (revisão), invariante: nenhuma assinatura `simulated` em produção —
# certificado simulado onde o interruptor signature_psc_mock não existe é
# recusado aqui (defesa em profundidade atrás de Providers), sem gravar nada.
module Signatures
  module Signing
    KINDS = Signer::KINDS
    SIMULATED = "simulated".freeze

    # failed: [[SignatureRequest, reason]]. final: ids dos pedidos cuja falha
    # não deve ser tentada de novo, mesmo com motivo passageiro.
    Outcome = Data.define(:signed, :failed, :final) do
      def initialize(signed:, failed:, final: []) = super
      def inspect = "#<Signatures::Signing::Outcome signed=#{signed.size} failed=#{failed.size}>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    module_function

    def call(requests:, access_token:, certificate:, now: Time.current, signer: Signer.client, env: Rails.env)
      raise ArgumentError, "pedido de outro autor" if requests.any? { |request| request.author_user_id != certificate.user_id }

      simulated = certificate.provider == SIMULATED
      if simulated && Platform::Features.find(PscMock::KEY, env: env).nil?
        return Outcome.new(signed: [], failed: requests.map { |request| [ request, "provider_unavailable" ] },
                           final: requests.map(&:id))
      end
      unless CertificateRules.cpf_matches?(certificate)
        return Outcome.new(signed: [], failed: requests.map { |request| [ request, "certificate_cpf_mismatch" ] })
      end

      info = certificate.info
      ready = []
      failed = []
      final = []
      chain = {}   # [document_type, document_id] => canonical_sha256 dos já preparados neste lote
      blocked = {} # consultation_id => [motivo, definitivo?] da primeira falha (os seguintes da mesma consulta não assinam)
      verdict = nil # motivo do certificado (R9): vale para todos os pedidos
      # Ordem cronológica de criação dos documentos: a consulta, depois os adendos.
      chronological(requests).each do |request|
        next failed << [ request, verdict ] if verdict
        next block(request, *blocked[request.consultation_id], failed, final) if blocked.key?(request.consultation_id)

        docs = Documents.for(request, info: info, signed_at: now, chain: chain, simulated: simulated)
        prepared = KINDS.to_h do |kind|
          [ kind, signer.prepare(kind: kind, document: kind == "cades" ? docs.canonical.json : docs.pdf, certificate_der: certificate.der) ]
        end
        chain[[ request.document_type, request.document_id ]] = docs.canonical.sha256
        ready << [ request, docs, prepared ]
      rescue Signer::Rejected => e
        if e.code == "invalid_certificate"
          verdict = certificate_verdict(certificate, signer)
          failed << [ request, verdict ]
        else
          blocked[request.consultation_id] ||= [ "verification_failed", true ]
          block(request, "verification_failed", true, failed, final)
        end
      rescue Canonical::Invalid, Consultations::Print::NotPrintable
        blocked[request.consultation_id] ||= [ "verification_failed", false ]
        block(request, "verification_failed", false, failed, final)
      end
      if verdict
        # O certificado não serve: nada do lote vai ao PSC.
        mark!(certificate, verdict)
        return Outcome.new(signed: [], failed: requests.map { |request| [ request, verdict ] })
      end
      return Outcome.new(signed: [], failed: failed, final: final) if ready.empty?

      digests = ready.each_with_object({}) do |(request, _docs, prepared), map|
        KINDS.each { |kind| map["#{request.id}:#{kind}"] = prepared[kind].digest }
      end
      raw = Psc::Client.for(certificate.provider).sign(access_token: access_token, certificate_alias: certificate.certificate_alias,
                                                       digests: digests)
      signed = []
      # Só falha de gravação bloqueia aqui: o pedido em `ready` é anterior a
      # qualquer falha de preparo da mesma consulta (ordem cronológica).
      unstored = {} # consultation_id => motivo
      ready.each do |request, docs, prepared|
        next failed << [ request, unstored[request.consultation_id] ] if unstored.key?(request.consultation_id)

        result = store(request, docs, prepared, raw, certificate, info, signer, now)
        if result.is_a?(Signature)
          signed << result
        else
          unstored[request.consultation_id] = result
          failed << [ request, result ]
          mark!(certificate, result)
        end
      end
      Outcome.new(signed: signed, failed: failed, final: final)
    end

    # Consulta pela finalização, adendo pela criação; desempate pelo id do pedido.
    def chronological(requests)
      requests.sort_by do |request|
        document = request.document
        time = case document
               when Consultation then document.finalized_at
               when ConsultationAddendum then document.created_at
               end
        [ time || request.created_at, request.id ]
      end
    end

    def block(request, reason, definitive, failed, final)
      failed << [ request, reason ]
      final << request.id if definitive
    end

    # R9: uma consulta a /certificates/check diz por que o signer recusou o
    # certificado. Signer::Unavailable sobe (antes do PSC: passageiro).
    def certificate_verdict(certificate, signer)
      check = signer.check_certificate(certificate_der: certificate.der)
      return "certificate_revoked" if check.reasons.include?("certificate_revoked")
      return "certificate_expired" if check.reasons.include?("certificate_expired")

      "verification_failed"
    rescue Signer::Rejected
      "verification_failed"
    end

    # O certificado revogado/vencido não volta a ser usado (o vínculo cai).
    def mark!(certificate, reason)
      status = { "certificate_revoked" => "revoked", "certificate_expired" => "expired" }[reason]
      certificate.update!(status: status) if status && certificate.status != status
    end

    def store(request, docs, prepared, raw, certificate, info, signer, now)
      cades = signer.assemble(kind: "cades", state: prepared["cades"].state, signature_value: raw.fetch("#{request.id}:cades"))
      pades = signer.assemble(kind: "pades", state: prepared["pades"].state, signature_value: raw.fetch("#{request.id}:pades"))
      checks = [ signer.verify(kind: "cades", signature: cades.signature, document: docs.canonical.json),
                 signer.verify(kind: "pades", signature: pades.signature) ]
      reason = rejection(checks, info)
      return reason if reason

      ApplicationRecord.transaction(requires_new: true) do
        signature = Signature.create!(
          signature_request: request, document_type: request.document_type, document_id: request.document_id,
          canonical_json: docs.canonical.json, canonical_sha256: docs.canonical.sha256,
          cades: Base64.strict_encode64(cades.signature), signed_pdf: Base64.strict_encode64(pades.signature),
          pdf_sha256: Digest::SHA256.hexdigest(pades.signature), policy: "AD-RB", policy_oid: checks.first.policy_oid,
          provider: certificate.provider,
          validation_material: { "cades" => Base64.strict_encode64(cades.validation_material),
                                 "pades" => Base64.strict_encode64(pades.validation_material) }.to_json,
          signer_certificate: certificate, signer_cpf: info.cpf, signed_at: checks.first.signed_at || now,
          last_verification: "valid", last_verification_at: now, last_verification_reasons: []
        )
        request.update!(status: "signed", reason_code: nil, resolved_at: now)
        DomainEvents.publish("signature.signed", signature_id: signature.id, request_id: request.id,
                                                 document_type: DocumentTypes.api(request.document_type), document_id: request.document_id)
        signature
      end
    rescue Signer::Rejected
      "verification_failed"
    rescue Signer::Unavailable
      "signer_unavailable" # depois do PSC: o lote não perde os já gravados; o job tenta de novo
    end

    def rejection(checks, info)
      return "certificate_revoked" if checks.any? { |check| check.reasons.include?("certificate_revoked") }
      return "certificate_cpf_mismatch" if checks.any? { |check| check.signer_cpf.present? && check.signer_cpf != info.cpf }
      return "verification_failed" unless checks.all?(&:valid?)

      nil
    end
    private_class_method :store, :rejection, :chronological, :block, :certificate_verdict, :mark!
  end
end
