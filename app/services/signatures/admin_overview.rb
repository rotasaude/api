# Painel do admin municipal (ADR 0032; spec §9; contrato §7). Só leitura; sem
# CPF, sem conteúdo clínico. Nenhuma coluna cifrada é lida.
module Signatures
  module AdminOverview
    LIMIT = 500
    INVALID_LIMIT = 200

    module_function

    def call(range:, now: Time.current)
      { professionals: professionals(now), documents_by_mode: documents_by_mode(range), invalid_or_indeterminate: invalid }
    end

    def professionals(now)
      certificates = SignerCertificate.active.select(:id, :user_id, :not_after).index_by(&:user_id)
      pending = SignatureRequest.pending.group(:author_user_id)
                                .pluck(:author_user_id, Arel.sql("count(*)"), Arel.sql("min(created_at)"))
                                .to_h { |user_id, count, oldest| [ user_id, [ count, oldest ] ] }
      Professional.joins(:user).where(users: { deactivated_at: nil }).order(:professional_name).limit(LIMIT).map do |professional|
        certificate = certificates[professional.user_id]
        count, oldest = pending[professional.user_id]
        { user_id: professional.user_id, name: professional.professional_name,
          certificate_status: certificate_status(certificate, now), not_after: certificate&.not_after&.iso8601,
          expires_in_days: certificate&.expires_in_days(now),
          pending_count: count.to_i, oldest_pending_at: oldest&.in_time_zone&.iso8601 }.compact
      end
    end

    def certificate_status(certificate, now)
      return "none" unless certificate

      certificate.expiring?(now) ? "expiring" : "active"
    end

    def documents_by_mode(range)
      consultations = Consultation.where(status: "finalized", finalized_at: range)
      addenda = ConsultationAddendum.where(created_at: range)
      statuses = SignatureRequest.where(document_type: "Consultation", document_id: consultations.select(:id))
                                 .or(SignatureRequest.where(document_type: "ConsultationAddendum", document_id: addenda.select(:id)))
                                 .group(:status).count
      digital = statuses.fetch("signed", 0)
      pending = statuses.fetch("pending", 0) + statuses.fetch("failed", 0)
      { digital: digital, pending: pending, manual: consultations.count + addenda.count - digital - pending }
    end

    # `simulated` sempre booleano (R5): marcador legal não depende de ausência.
    def invalid
      Signature.where.not(last_verification: "valid").order(last_verification_at: :desc).limit(INVALID_LIMIT)
               .select(:id, :document_type, :signature_request_id, :provider, :last_verification, :last_verification_at)
               .includes(signature_request: { author_user: :professional }).map do |signature|
        { signature_id: signature.id, document_type: DocumentTypes.api(signature.document_type),
          signer_name: Screenings::Json.staff_name(signature.signature_request.author_user),
          verification: signature.last_verification, verified_at: signature.last_verification_at.iso8601,
          simulated: signature.provider == "simulated" }
      end
    end
    private_class_method :professionals, :certificate_status, :documents_by_mode, :invalid
  end
end
