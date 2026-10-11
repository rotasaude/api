# app/commands/consultation_drafts/reassign.rb
# Designar o rascunho de consulta órfão a outro profissional da unidade (card
# rotasaude/api#51; módulo 19a, ADR 0031): quem pode registrar consulta ali
# (Consultations::Authorization.link_for == :ok — papel, vínculo ativo, CBO do
# 19a) e com a conta ativa. Troca autora, vínculo e CBO da consulta e quem
# chamou o atendimento in_care (é o que Start, Access.in_context? e a fila
# usam); texto e draft_items ficam. As regras de CID-10 seguem na finalização
# pelo CBO novo. Só sob Consultation.with_draft_admin (trigger). Ordem de
# travas: atendimento → consulta → vínculo (FOR SHARE, no link_for). O papel
# (municipal_admin) e o step-up são do controlador.
module ConsultationDrafts
  module Reassign
    module_function

    def call(consultation_id:, user_id:, reason:, by:, city: Current.city)
      note = Reason.normalize(reason)
      return Result.fail(:invalid_reason) unless note
      return Result.fail(:feature_disabled) unless ClinicalRecord::Gate.usable?(city)
      return Result.fail(:not_found) unless ClinicalDocuments::Uuid.valid?(consultation_id)

      ApplicationRecord.transaction(requires_new: true) do
        consultation = Consultation.find_by(id: consultation_id)
        next Result.fail(:not_found) unless consultation

        attendance = Attendance.lock.find(consultation.attendance_id)
        consultation.lock!
        next Result.fail(:not_draft) unless consultation.draft?

        previous_id = consultation.author_user_id
        next Result.fail(:same_author) if user_id.to_s == previous_id

        user = ClinicalDocuments::Uuid.valid?(user_id) ? User.find_by(id: user_id) : nil
        next Result.fail(:invalid_professional) unless user&.active?

        status, link = Consultations::Authorization.link_for(user: user, health_unit_id: attendance.health_unit_id)
        next Result.fail(:invalid_professional) unless status == :ok

        Consultation.with_draft_admin do
          consultation.update!(author_user_id: user.id, professional_link_id: link.id, cbo_code: link.cbo_code)
          attendance.update!(called_by_user_id: user.id)
          ConsultationDraftAction.create!(consultation: consultation, attendance_id: consultation.attendance_id,
                                          action: "reassigned", previous_author_user_id: previous_id,
                                          new_author_user_id: user.id, by_user_id: by.id, reason: note)
        end
        DomainEvents.publish("consultation.draft_reassigned", consultation_id: consultation.id,
                                                              attendance_id: attendance.id,
                                                              previous_author_user_id: previous_id,
                                                              new_author_user_id: user.id, by_user_id: by.id)
        Result.ok(consultation: consultation)
      end
    end
  end
end
