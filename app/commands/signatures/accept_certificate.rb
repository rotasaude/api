# app/commands/signatures/accept_certificate.rb
# Aceita o certificado lido do PSC (ADR 0032; spec §5; NGS2.01.02, 01.03,
# 02.02): do CPF do profissional, dentro da validade, com digitalSignature +
# nonRepudiation e, no signer (contrato D1: cadeia + LCR), de cadeia conhecida e
# não revogado (indeterminate aceita e guarda o motivo). Mesmo serial do mesmo
# PSC no active: nada muda. Outro: o anterior vira replaced e a sessão ativa cai.
module Signatures
  module AcceptCertificate
    module_function

    def call(user:, provider:, entries:, now: Time.current, signer: Signer.client)
      cpf = user.professional&.cpf
      return Result.fail(:professional_cpf_missing) if cpf.blank?

      infos = entries.filter_map { |entry| parse(entry) }
      return Result.fail(:certificate_not_found) if infos.empty?

      mine = infos.select { |_entry, info| info.cpf == cpf }
      return Result.fail(:certificate_cpf_mismatch) if mine.empty?

      usable = mine.select { |_entry, info| info.signing_usage? }
      return Result.fail(:certificate_not_found) if usable.empty?

      current = usable.reject { |_entry, info| info.expired?(now) }
      return Result.fail(:certificate_expired) if current.empty?

      entry, info = current.max_by { |_entry, candidate| candidate.not_after }
      check = signer.check_certificate(certificate_der: info.der)
      return Result.fail(:certificate_cpf_mismatch) if check.signer_cpf.present? && check.signer_cpf != cpf
      if check.status == "invalid"
        return Result.fail(:certificate_revoked) if check.reasons.include?("certificate_revoked")
        return Result.fail(:certificate_expired) if check.reasons.include?("certificate_expired")

        return Result.fail(:certificate_untrusted) # untrusted_chain (e qualquer outra recusa da cadeia)
      end

      # indeterminate (LCR fora do ar): aceita e guarda o motivo; a revogação
      # volta a ser conferida no /verify da primeira assinatura.
      store(user, provider, entry, info, now, check)
    rescue Signer::Unavailable, Signer::Rejected # 422 invalid_certificate do signer também
      Result.fail(:signer_unavailable)
    end

    def parse(entry)
      [ entry, CertificateInfo.parse(entry.der) ]
    rescue CertificateInfo::Invalid
      nil
    end

    # Savepoint próprio: a corrida com outro vínculo do mesmo usuário (índice
    # parcial de um active por usuário) desfaz só este bloco e relê o vencedor.
    def store(user, provider, entry, info, now, check)
      ApplicationRecord.transaction(requires_new: true) do
        active = SignerCertificate.active.lock.find_by(user_id: user.id)
        next Result.ok(certificate: active, changed: false) if active && active.serial_number == info.serial_number && active.provider == provider

        active&.update!(status: "replaced")
        SignatureSession.active.where(user_id: user.id).update_all(status: "revoked", updated_at: now)
        certificate = SignerCertificate.create!(
          user: user, provider: provider, certificate_alias: entry.certificate_alias, serial_number: info.serial_number,
          issuer_dn: info.issuer_dn, subject_cpf: info.cpf, not_before: info.not_before, not_after: info.not_after,
          status: "active", certificate_der: Base64.strict_encode64(info.der),
          link_check_status: check.status, link_check_reasons: check.reasons
        )
        DomainEvents.publish("signature.certificate_linked", certificate_id: certificate.id, user_id: user.id, provider: provider)
        Result.ok(certificate: certificate, changed: true)
      end
    rescue ActiveRecord::RecordNotUnique
      # Outro vínculo do mesmo usuário gravou o active entre a leitura e o
      # create!: vale o que ficou gravado (é do próprio usuário), sem troca.
      winner = SignerCertificate.active.find_by(user_id: user.id)
      raise unless winner

      Result.ok(certificate: winner, changed: false)
    end
    private_class_method :parse, :store
  end
end
