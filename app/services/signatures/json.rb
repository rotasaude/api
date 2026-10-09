# app/services/signatures/json.rb
# Formas do contrato do 19b (contrato §3–§6). O provider sai como gravado
# (inclusive `simulated`).
module Signatures
  module Json
    module_function

    def certificate(certificate, now: Time.current)
      { id: certificate.id, provider: certificate.provider, issuer: certificate.info.issuer_name,
        serial_number: certificate.serial_number, not_after: certificate.not_after.iso8601, status: certificate.status,
        expires_in_days: certificate.expires_in_days(now) }
    end

    def session(session)
      return { active: false } unless session

      { active: true, expires_at: session.expires_at.iso8601, provider: session.provider }
    end

    # <signature> (contrato §6). O CPF só mascarado; o conteúdo é o JSON
    # canônico; signer_name = nome cadastrado do autor (§13). provider sempre e
    # simulated SEMPRE booleano (R5).
    def signature(signature)
      { id: signature.id, document_type: DocumentTypes.api(signature.document_type), document_id: signature.document_id,
        signed_at: signature.signed_at.iso8601, signer_name: Screenings::Json.staff_name(signature.signature_request.author_user),
        signer_cpf_masked: CitizenIdentity::Cpf.mask(signature.signer_cpf), policy: signature.policy,
        provider: signature.provider, simulated: signature.simulated?,
        verification: signature.last_verification, verification_reasons: signature.last_verification_reasons,
        verified_at: signature.last_verification_at.iso8601, content: JSON.parse(signature.canonical_json) }
    end

    # <request> (contrato §5, §13), sem N+1: consultas e adendos numa consulta
    # só. reason_code só quando há; patient_display_name pode ser nulo.
    def requests(rows)
      consultations = Consultation.where(id: rows.map(&:consultation_id)).includes(:patient).index_by(&:id)
      addendum_ids = rows.select { |row| row.document_type == "ConsultationAddendum" }.map(&:document_id)
      addenda = ConsultationAddendum.where(id: addendum_ids).pluck(:id, :created_at).to_h
      rows.map do |row|
        consultation = consultations[row.consultation_id]
        finalized_at = row.document_type == "Consultation" ? consultation&.finalized_at : addenda[row.document_id]
        { id: row.id, document_type: DocumentTypes.api(row.document_type), document_id: row.document_id,
          consultation_id: row.consultation_id, patient_display_name: consultation&.patient&.display_name,
          finalized_at: finalized_at&.iso8601, status: row.status, reason_code: row.reason_code, attempts: row.attempts }
          .tap { |item| item.delete(:reason_code) if item[:reason_code].nil? }
      end
    end
  end
end
