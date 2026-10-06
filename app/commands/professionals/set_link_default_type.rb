# Tipo padrão do vínculo (ADR 0029 §3.2): vale para o turno sem modelo. Tem de
# ser um tipo ativo que atende o CBO do vínculo; nil limpa.
module Professionals
  module SetLinkDefaultType
    module_function

    def call(link:, appointment_type_key:, by:)
      key = appointment_type_key.presence&.to_s

      ApplicationRecord.transaction(requires_new: true) do
        if key
          type = AppointmentType.lock("FOR SHARE").find_by(key: key)
          next Result.fail(:type_not_served) unless type && Scheduling::AppointmentTypes.serves?(type, link.cbo_code)
          next Result.fail(:inactive_type) unless type.active
        end

        link.lock!
        next Result.fail(:already_ended) unless link.active?

        link.update!(default_appointment_type_key: key)
        DomainEvents.publish("professional.link_default_type_set", professional_link_id: link.id,
                                                                   appointment_type_key: key, by_user_id: by.id)
        Result.ok(link: link)
      end
    end
  end
end
