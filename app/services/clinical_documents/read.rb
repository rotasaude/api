# app/services/clinical_documents/read.rb
# Quem lê um documento clínico (ADR 0033; contrato §3, preâmbulo): a autora do
# documento sempre (inclusive a recepção, a própria declaração); os demais
# pelas regras do 19a — pela consulta (rascunho só da autora; finalizada por
# ClinicalRecord::Access.for_consultation) ou, na declaração do atendimento,
# pelo paciente e pelo atendimento (ClinicalRecord::Access.call).
module ClinicalDocuments
  module Read
    Grant = ClinicalRecord::Access::Grant

    module_function

    def consultation_grant(user:, consultation:)
      return deny(:missing_role) unless user.has_role?("health_professional")
      # Descartada (card api#51): casca, nunca o ramo da finalizada.
      return deny(:not_found) if consultation.discarded?
      return consultation.author_user_id == user.id ? Grant.new(kind: :in_context, opening: nil, reason: nil) : deny(:not_author) if consultation.draft?

      ClinicalRecord::Access.for_consultation(user: user, consultation: consultation)
    end

    def document_grant(user:, document:, health_unit_id: nil)
      staff = user.has_role?("health_professional") || user.has_role?("citizen_verifier")
      return Grant.new(kind: :author, opening: nil, reason: nil) if staff && document.author_user_id == user.id
      # api#59: a recepção da unidade do atendimento (a escolhida no seletor) lê a
      # declaração de comparecimento emitida por colegas — só esse tipo.
      return Grant.new(kind: :unit_reception, opening: nil, reason: nil) if unit_reception?(user, document, health_unit_id)
      # Documento emitido num rascunho depois descartado (card api#51): segue
      # válido; lê-se pelo paciente e pelo atendimento, como a declaração.
      return consultation_grant(user: user, consultation: document.consultation) if document.consultation && !document.consultation.discarded?

      ClinicalRecord::Access.call(user: user, patient: document.patient, attendance: document.attendance)
    end

    def unit_reception?(user, document, health_unit_id)
      document.kind == "attendance_declaration" && user.has_role?("citizen_verifier") &&
        health_unit_id.present? && document.attendance.health_unit_id == health_unit_id
    end

    def deny(reason) = Grant.new(kind: :denied, opening: nil, reason: reason)
    private_class_method :deny
  end
end
