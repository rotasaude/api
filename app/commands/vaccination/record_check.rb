# Conferência da caderneta na sala (ADR 0047, Desvio 10; contrato §5): só
# `confirmed_complete` por aqui — `transcribed` nasce da transcrição com
# `close_check: true` e `born_after_go_live` do Vaccination::Statuses. A
# conferência é imutável (trigger); uma nova só se acrescenta. Na mesma
# transação: a situação materializada recalculada, o evento
# `vaccination.record_checked` (só ids) e a trilha da pessoa mostrada.
module Vaccination
  module RecordCheck
    MODE = "confirmed_complete".freeze

    module_function

    # -> Result.ok(check:) | fail(:invalid_request, details: { path: "mode", problems: })
    def call(room:, patient:, mode:, by:, now: Time.current, today: Time.zone.today)
      return refuse("mode") unless mode == MODE

      VaccinationRecordCheck.transaction(requires_new: true) do
        check = VaccinationRecordCheck.create!(patient: patient, vaccine_room: room, checked_by_user: by, mode: MODE, checked_at: now)
        Statuses.refresh!(patient, today: today)
        DomainEvents.publish("vaccination.record_checked", vaccination_record_check_id: check.id, vaccine_room_id: room.id, user_id: by.id)
        Trail.person_viewed!(user: by, patient_id: patient.id)
        Result.ok(check: check)
      end
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })
    private_class_method :refuse
  end
end
