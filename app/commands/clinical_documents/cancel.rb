# app/commands/clinical_documents/cancel.rb
# Cancelamento (ADR 0033; spec §6; contrato §3): só a autora, com motivo de
# 10 a 500 caracteres (cifrado; nunca em log ou evento). O documento fica
# `cancelled` (o trigger só aceita esta transição). Depois do commit, o pedido
# de assinatura pendente sai da fila se ninguém o estiver assinando (SKIP
# LOCKED); senão o job, o lote ou a varredura o tiram (Desvio 6). Cancelar
# não desfaz medicamento já entregue (aviso na tela).
module ClinicalDocuments
  module Cancel
    module_function

    # health_unit_id (api#59): a unidade do seletor; com ela, a recepção cancela a
    # declaração de comparecimento de um atendimento da unidade, mesmo de colega.
    def call(document_id:, by:, reason:, health_unit_id: nil, now: Time.current)
      note = reason.is_a?(String) ? reason.squish : ""
      return Result.fail(:invalid_reason) unless ClinicalDocument::CANCEL_REASON.cover?(note.size)
      return Result.fail(:not_found) unless Uuid.valid?(document_id)

      result = ApplicationRecord.transaction do
        document = ClinicalDocument.lock.find_by(id: document_id)
        next Result.fail(:not_found) unless document
        unless document.author_user_id == by.id
          next Result.fail(:not_author) unless document.kind == "attendance_declaration" && by.has_role?("citizen_verifier")
          next Result.fail(:attendance_outside_unit) unless health_unit_id.present? && document.attendance.health_unit_id == health_unit_id
        end
        next Result.fail(:already_cancelled) if document.cancelled?

        document.update!(status: "cancelled", cancel_reason: note, cancelled_at: now, cancelled_by_user_id: by.id)
        Sncr::Stock.void!(document: document, now: now) # ADR 0034: número de receita cancelada não volta
        payload = { document_id: document.id, kind: document.kind }
        payload[:category] = document.content_data["category"] if document.prescription? && document.content_data["category"]
        DomainEvents.publish("clinical_document.cancelled", **payload)
        Result.ok(document: document)
      end
      retire(result.payload[:document], now) if result.ok?
      result
    end

    # Transação própria, depois do commit do cancelamento: o job/lote que
    # segura o pedido (FOR UPDATE SKIP LOCKED) não trava o cancelamento, e ao
    # soltá-lo já vê o documento cancelado. O cancelamento já está gravado:
    # uma falha aqui não vira 500 (repetir daria um 409 confuso); o job, o lote
    # ou a varredura retiram o pedido depois. Log só com a classe e os ids.
    def retire(document, now)
      ApplicationRecord.transaction do
        request = SignatureRequest.lock("FOR UPDATE SKIP LOCKED")
                                  .find_by(document_type: "ClinicalDocument", document_id: document.id, status: "pending")
        Signatures::CancelledDocuments.retire!([ request ], now: now) if request
      end
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[ClinicalDocuments::Cancel] retire deferred: #{e.class} document_id=#{document.id}")
    end
    private_class_method :retire
  end
end
