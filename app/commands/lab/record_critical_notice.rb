# Registro da comunicação do valor crítico (spec §5.7; RDC 978 art. 154, III
# e 165): quem foi avisado, papel, canal, quando; quem registrou. Antes ou
# depois da liberação. Nome de quem foi avisado cifrado; evento só com ids.
# notified_at: entre o recebimento da amostra (ou coleta) e agora + 1 min — o
# aviso pode vir antes da digitação ou da escolha da cópia.
# Um aviso por resultado: o segundo é `conflict` (409), sem duplicar a história.
module Lab
  module RecordCriticalNotice
    PERSON_MAX = 120
    ROLE_MAX = 60
    FUTURE_TOLERANCE = 1.minute

    module_function

    def call(result_id:, notified_person:, notified_role:, channel:, notified_at:, by:, now: Time.current)
      result = result_id.is_a?(String) && result_id.match?(Lab::BaseController::UUID) && LabResult.find_by(id: result_id)
      return Result.fail(:not_found) unless result
      return Result.fail(:missing_role) unless Access.member?(by, result.lab_requisition_item.lab_requisition.exam_provider_id)
      return Result.fail(:not_critical) unless result.critical?

      person = notified_person.is_a?(String) ? notified_person.strip : ""
      role = notified_role.is_a?(String) ? notified_role.strip : ""
      at = (Time.iso8601(notified_at.to_s) rescue nil)
      sample = result.lab_requisition_item.lab_sample
      floor = sample.received_at || sample.collected_at
      valid = person.length.between?(1, PERSON_MAX) && role.length.between?(1, ROLE_MAX) && LabCriticalNotice::CHANNELS.include?(channel) &&
              at && at <= now + FUTURE_TOLERANCE && (floor.nil? || at.to_i >= floor.to_i)
      return Result.fail(:invalid_notice) unless valid

      ApplicationRecord.transaction(requires_new: true) do
        result.lock!
        next Result.fail(:conflict) if LabCriticalNotice.exists?(lab_result_id: result.id)

        notice = LabCriticalNotice.create!(lab_result: result, notified_person: person, notified_role: role, channel: channel,
                                           notified_at: at, recorded_by_user: by, created_at: now)
        DomainEvents.publish("lab_critical.notified", lab_critical_notice_id: notice.id, lab_result_id: result.id)
        Result.ok(notice: notice)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:conflict) # savepoint desfeito: a transação de fora segue viva
    end
  end
end
