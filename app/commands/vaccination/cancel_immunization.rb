# Cancelamento da dose, com a substituição na mesma transação (ADR 0047,
# Desvios 7, 9, 12 e 13; contrato §5; §15 V6, V7; Review Focus 1 e 3).
#
# Quem cancela: o autor da dose ou o `room_lead` da sala dela (o step-up é do
# controlador). Motivo de 10 a 500 caracteres, cifrado. Tudo numa transação,
# sob as travas do módulo (lotes → local → documento): os lotes da dose e da
# substituta, o local da sala, e a dose FOR UPDATE (já cancelada →
# `already_cancelled`). Então:
#  1. grava `cancelled_at`, `cancelled_by_user_id` e `cancel_reason` (uma vez);
#  2. unidose com lote do estoque → `immunization_reversal` (+1) no local da
#     sala (o frasco multidose nunca recebe reversão: a dose volta ao frasco
#     porque a contagem só soma doses ativas);
#  3. fila RNDS: a entrada `cancellation` só nasce se a `application` do
#     original já foi tentada (`RndsOutboxEntry#attempted?`: `sending`,
#     `accepted`, ou `pending` depois de uma tentativa) e não está
#     `rejected`/`failed` (nada a desfazer na RNDS). `application` `pending`
#     sem tentativa (inclusive com o envio desligado), `blocked` ou ausente:
#     a dose nunca chegou à RNDS e não vai mais (`RndsOutboxEntry.withdrawn`,
#     excluída do claim da Task 13); nenhuma `cancellation`;
#  4. a substituta, com `replaces_id`: pelo Vaccination::RecordImmunization
#     (forma do POST da dose), ou, se o original é uma transcrição, como um item
#     de transcrição. Recusa da substituta desfaz tudo (V6) e volta com os
#     problemas no path `replacement.<campo>`;
#  5. a situação materializada, `vaccination.immunization_cancelled` (só ids) e
#     uma trilha pela pessoa mostrada (a substituta pelo RecordImmunization já
#     grava a dela; a de transcrição, não — a trilha é gravada aqui).
module Vaccination
  module CancelImmunization
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    NOTHING_TO_UNDO = %w[rejected failed].freeze

    module_function

    # -> Result.ok(cancelled:, replacement:) | fail(:invalid_reason, details: { path: "reason" })
    #    | fail(:cancel_not_allowed) | fail(:already_cancelled) | fail(:invalid, details: { path:, problems: })
    #    | fail(:missing_role) (a substituta exige vínculo de vacinador) | fail(:location_inactive)
    def call(immunization:, reason:, replacement:, by:, now: Time.current)
      clean = reason.is_a?(String) ? reason.strip : nil
      return Result.fail(:invalid_reason, details: { path: "reason" }) unless clean && Catalog::REASON.cover?(clean.length)
      return Result.fail(:cancel_not_allowed) unless allowed?(immunization, by)

      shape = replacement_shape(replacement, immunization)
      return shape if shape.is_a?(Result)

      result = nil
      Immunization.transaction(requires_new: true) do
        result = cancel!(immunization, clean, shape, by, now)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def allowed?(dose, user)
      return true if dose.vaccinator_user_id == user.id

      dose.vaccine_room.present? && Access.room_roles(user: user, room: dose.vaccine_room).include?("room_lead")
    end

    # nil (sem substituta) | Hash (corpo sem patient_id) | Result (recusa).
    def replacement_shape(replacement, dose)
      return nil if replacement.nil?
      return refuse([ { path: "replacement", error: "invalid_request" } ]) unless replacement.is_a?(Hash)

      attrs = replacement.transform_keys(&:to_s)
      patient_id = attrs.delete("patient_id")
      return refuse([ { path: "replacement.patient_id", error: "invalid_value" } ]) unless patient_id.nil? || patient_id == dose.patient_id

      attrs
    end

    def cancel!(dose, reason, attrs, by, now)
      room = dose.vaccine_room
      lot_ids = [ dose.stock_lot_id ]
      lot_ids << attrs["lot_id"] if attrs && !dose.transcription && attrs["lot_id"].is_a?(String) && attrs["lot_id"].match?(UUID)
      locked = Pharmacy::Ledger.lock_lots!(lot_ids)
      location = Pharmacy::Ledger.lock_location!(room.stock_location_id) if dose.stock_lot_id
      dose = Immunization.lock("FOR UPDATE").find(dose.id)
      return Result.fail(:already_cancelled) if dose.cancelled?

      dose.update!(cancelled_at: now, cancelled_by_user: by, cancel_reason: reason)
      if dose.stock_lot_id && dose.vial_opening_id.nil?
        Pharmacy::Ledger.record!(location: location, lot: locked.fetch(dose.stock_lot_id), kind: "immunization_reversal", quantity: 1,
                                 by: by, document: dose, at: now)
      end
      enqueue_cancellation!(dose, now)

      substitute = nil
      if attrs
        made = replace!(dose, attrs, by, now)
        return made if made.failure?

        substitute = made.payload.fetch(:immunization)
      end
      Statuses.refresh!(dose.patient, today: now.in_time_zone.to_date)
      DomainEvents.publish("vaccination.immunization_cancelled", immunization_id: dose.id, vaccine_room_id: dose.vaccine_room_id,
                                                                 user_id: by.id, replacement_id: substitute&.id)
      Trail.person_viewed!(user: by, patient_id: dose.patient_id) unless substitute && !dose.transcription
      Result.ok(cancelled: dose, replacement: substitute)
    rescue Pharmacy::Ledger::Inactive
      Result.fail(:location_inactive)
    end

    # A `application` travada contra o job de envio (Task 13) enquanto decide:
    # o claim (SKIP LOCKED) não a pega no meio.
    def enqueue_cancellation!(dose, now)
      application = RndsOutboxEntry.lock("FOR UPDATE").find_by(immunization_id: dose.id, kind: "application")
      return if application.nil? || !application.attempted? || NOTHING_TO_UNDO.include?(application.status)

      Rnds::Enqueue.call(dose, kind: "cancellation", now: now)
    end

    # -> Result.ok(immunization:) | fail(:invalid, problems com replacement.*) | fail(:missing_role)
    def replace!(dose, attrs, by, now)
      made = if dose.transcription
        transcribed(dose, attrs, by, now)
      else
        RecordImmunization.call(room: dose.vaccine_room, patient: dose.patient, attrs: attrs, by: by, now: now, replaces: dose)
      end
      return made if made.ok? || made.reason != :invalid

      refuse(made.details.fetch(:problems).map { |problem| problem.merge(path: "replacement.#{problem[:path]}") })
    end

    def transcribed(dose, attrs, by, now)
      link = Access.vaccinator_link(user: by, room: dose.vaccine_room)
      return Result.fail(:missing_role) unless link

      row = RecordTranscription::Item.new(attrs, "", dose.patient, now)
      problems = row.problems.map { |problem| problem.merge(path: problem[:path].delete_prefix(".")) }
      return Result.fail(:invalid, details: { path: problems.first[:path], problems: problems }) if problems.any?

      Result.ok(immunization: RecordTranscription.write!(row, room: dose.vaccine_room, patient: dose.patient, by: by, link: link, now: now,
                                                         replaces: dose))
    end

    def refuse(problems) = Result.fail(:invalid, details: { path: problems.first[:path], problems: problems })

    private_class_method :allowed?, :replacement_shape, :cancel!, :enqueue_cancellation!, :replace!, :transcribed, :refuse
  end
end
