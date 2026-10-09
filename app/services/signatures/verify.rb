# app/services/signatures/verify.rb
# Revalidação (ADR 0032; spec §5; NGS2.03.01: ao abrir, imprimir e sob
# demanda). Revogação posterior muda só o estado de validação; o registro não
# muda (trigger). signer fora do ar: devolve o estado guardado.
module Signatures
  module Verify
    module_function

    def call(signature, now: Time.current, signer: Signer.client, explicit: false)
      checks = [ signer.verify(kind: "cades", signature: signature.cades_bytes, document: signature.canonical_json),
                 signer.verify(kind: "pades", signature: signature.signed_pdf_bytes) ]
      status = combine(checks, signature)
      changed = status != signature.last_verification
      signature.update!(last_verification: status, last_verification_at: now,
                        last_verification_reasons: checks.flat_map(&:reasons).uniq)
      DomainEvents.publish("signature.verified", signature_id: signature.id, verification: status) if changed || explicit
      signature
    rescue Signer::Unavailable
      signature
    rescue Signer::Rejected => e
      # Recusa permanente do signer: devolve o guardado, mas aparece no log
      # (só o id e o código; nunca corpo, CPF ou conteúdo).
      Rails.logger.warn("[signatures.verify] signer recusou signature_id=#{signature.id} code=#{e.code}")
      signature
    end

    def combine(checks, signature)
      return "invalid" if checks.any? { |check| check.signer_cpf.present? && check.signer_cpf != signature.signer_cpf }
      return "valid" if checks.all?(&:valid?)
      return "invalid" if checks.any? { |check| check.status == "invalid" }

      "indeterminate"
    end
    private_class_method :combine
  end
end
