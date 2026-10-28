# app/commands/consultation_drafts/discard.rb
# Descartar o rascunho de consulta órfão (card rotasaude/api#51; módulo 19a,
# ADR 0031): marca, não apaga — `discarded`, conteúdo clínico zerado (S/O/A/P,
# sinais vitais, draft_items); a linha fica como casca e os documentos já
# emitidos não mudam. Só sob Consultation.with_draft_admin (trigger). Sem
# ficha, problema ou conduta. O atendimento segue in_care: o desfecho sai pela
# rota normal (Attendances::Close). Ordem de travas: atendimento → consulta
# (como Consultations::Finalize). O papel (municipal_admin) e o step-up são do
# controlador.
# Módulo 26a (ADR 0044; plano do api, Desvio 1): os rascunhos de regulação da
# consulta descartada somem na mesma transação (o trigger só deixa apagar
# `draft`; promovido nunca some).
module ConsultationDrafts
  module Discard
    module_function

    def call(consultation_id:, reason:, by:, city: Current.city)
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

        author_id = consultation.author_user_id
        Consultation.with_draft_admin do
          consultation.update!(Consultation::CLINICAL_COLUMNS.index_with(nil)
                                 .merge(status: "discarded", discarded_at: Time.current, draft_items: {}))
          ConsultationDraftAction.create!(consultation: consultation, attendance_id: consultation.attendance_id,
                                          action: "discarded", previous_author_user_id: author_id,
                                          by_user_id: by.id, reason: note)
        end
        RegulationRequest.where(consultation_id: consultation.id, status: "draft").delete_all
        DomainEvents.publish("consultation.draft_discarded", consultation_id: consultation.id,
                                                             attendance_id: attendance.id,
                                                             author_user_id: author_id, by_user_id: by.id)
        Result.ok(consultation: consultation)
      end
    end
  end
end
