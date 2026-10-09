# app/controllers/signatures/signatures_controller.rb
# Assinatura gravada (contrato §6, §13): conteúdo legível, PDF, pacote e
# revalidação. Atrás do clinical_record (o assinado continua visível com o
# digital_signature desligado) e das regras de leitura revisadas do 19a
# (ADR 0031, Revisão): a autora sempre (trilha author); outro profissional em
# contexto ou por abertura justificada (senão 403 opening_required); o
# municipal_admin só o conteúdo (sem PDF, pacote nem revalidação sob demanda),
# com step-up, linha em clinical_record_administrative_reads e trilha
# administrative. Quem tem os dois papéis tenta primeiro como profissional.
# Toda leitura deixa trilha clinical_record.viewed.
module Signatures
  class SignaturesController < BaseController
    include ClinicalRecordGate

    ADMIN_ACTIONS = %w[show].freeze

    skip_before_action :require_digital_signature!
    skip_before_action :require_professional
    before_action :require_clinical_record!
    before_action :require_reader_role
    before_action :set_signature
    before_action :authorize_read

    def show = render(json: Json.signature(Verify.call(@signature)))

    def verify = render(json: Json.signature(Verify.call(@signature, explicit: true)))

    def pdf
      Verify.call(@signature)
      response.headers["Cache-Control"] = "no-store"
      send_data @signature.signed_pdf_bytes, type: "application/pdf", disposition: "attachment", filename: "documento-assinado.pdf"
    end

    def package
      response.headers["Cache-Control"] = "no-store"
      send_data Package.zip(@signature), type: "application/zip", disposition: "attachment", filename: Package.filename(@signature)
    end

    private

    def policy = (@policy ||= CitizenVerificationPolicy.new(Current.user, nil))

    def require_reader_role
      forbid("missing_role") unless policy.care? || policy.manage?
    end

    def set_signature
      @signature = Signature.find_by(id: params[:id])
      return render(json: { error: "not_found" }, status: :not_found) unless @signature

      @consultation = Consultation.find(@signature.signature_request.consultation_id)
    end

    def authorize_read
      if policy.care?
        grant = ClinicalRecord::Access.for_consultation(user: Current.user, consultation: @consultation)
        return ClinicalRecord::Trail.viewed!(patient: @consultation.patient, user: Current.user, grant: grant) if grant.allowed?
        unless policy.manage? && ADMIN_ACTIONS.include?(action_name)
          return forbid(grant.reason == :out_of_context ? "opening_required" : grant.reason.to_s)
        end
      end

      administrative_read
    end

    # Igual à leitura administrativa da consulta do 19a
    # (ClinicalRecordConsultationsController#show): a linha e a trilha juntas.
    def administrative_read
      return forbid("missing_role") unless ADMIN_ACTIONS.include?(action_name)
      return render(json: { error: "mfa_required" }, status: :unauthorized) unless reauthenticated_recently?

      grant = ClinicalRecord::Access::Grant.new(kind: :administrative, opening: nil, reason: nil)
      ApplicationRecord.transaction do
        ClinicalRecordAdministrativeRead.create!(user: Current.user, patient: @consultation.patient, consultation: @consultation)
        ClinicalRecord::Trail.viewed!(patient: @consultation.patient, user: Current.user, grant: grant,
                                      consultation_id: @consultation.id)
      end
    end
  end
end
