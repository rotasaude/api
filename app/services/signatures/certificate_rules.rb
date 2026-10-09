# app/services/signatures/certificate_rules.rb
# Regras do certificado a CADA uso (ADR 0032; spec §5; NGS2.01.02): dentro da
# validade, não revogado, do CPF do profissional AGORA. nil = pode assinar.
module Signatures
  module CertificateRules
    module_function

    def reason(certificate, now: Time.current)
      if certificate.not_after <= now
        certificate.update!(status: "expired")
        return "certificate_expired"
      end
      return "certificate_revoked" if certificate.status == "revoked"
      return "certificate_cpf_mismatch" unless cpf_matches?(certificate)

      nil
    end

    # O CPF do certificado contra o do cadastro do profissional, agora.
    def cpf_matches?(certificate)
      cpf = certificate.user.professional&.cpf
      cpf.present? && certificate.info.cpf == cpf
    end
  end
end
