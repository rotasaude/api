# Tentativa de contato da busca ativa (contrato §5): só acréscimo; nota
# opcional, até 500, cifrada; só em inscrição ativa (conferida sob trava, para
# não gravar contato numa inscrição que acabou de ser encerrada).
module CareLines
  module RecordContact
    module_function

    def call(enrollment:, channel:, outcome:, note:, by:)
      return Result.fail(:invalid_channel) unless Catalog::CHANNELS.include?(channel)
      return Result.fail(:invalid_outcome) unless Catalog::OUTCOMES.include?(outcome)

      text = note.is_a?(String) ? note.strip.presence : nil
      return Result.fail(:too_long, details: { field: "note" }) if text && text.length > Catalog::TEXT_MAX

      ApplicationRecord.transaction do
        enrollment.lock!
        next Result.fail(:invalid_transition) unless enrollment.active?

        contact = CareOutreachContact.create!(enrollment: enrollment, channel: channel, outcome: outcome, note: text,
                                              recorded_by_user: by, recorded_at: Time.current)
        DomainEvents.publish("care_outreach.recorded", care_outreach_contact_id: contact.id, care_line_enrollment_id: enrollment.id,
                                                       user_id: by.id)
        Result.ok(contact: contact)
      end
    end
  end
end
