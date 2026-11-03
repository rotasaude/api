# Atendimento marcado no destino (contrato §6; plano, Desvio 12): a comissão
# informa `appointment_at` (ISO 8601 com fuso, depois de agora e até agora +
# 365 dias — a mesma regra da autorização, que recusa data passada; D6) e, opcionalmente, o prestador (Tfd::Providers) — sem `provider_id`,
# o prestador do laudo fica (Ruling Task 10: o prestador é do laudo). Só em `submitted`, `authorized` ou
# `scheduled`; grava o evento `appointment_set` sem mudar a situação
# (Tfd::Transition) e publica tfd.case_updated (só ids). A data e o
# prestador nunca vão para evento nem log.
module Tfd
  module SetAppointment
    OPEN = %w[submitted authorized scheduled].freeze
    FUTURE = 365.days

    module_function

    # -> Result.ok(tfd_case:) | fail(:missing_role | :invalid_request | :invalid_transition, path:, problems:)
    def call(tfd_case:, appointment_at:, by:, provider_id: nil, now: Time.current)
      return Result.fail(:missing_role) unless Access.committee?(by)

      time = parse(appointment_at)
      provider = provider(provider_id)
      paths = []
      paths << "appointment_at" unless time && time > now && time <= now + FUTURE
      paths << "provider_id" if provider == :invalid
      return Transport::Support.refuse(paths) if paths.any?

      TfdCase.transaction(requires_new: true) do
        tfd_case.lock!
        next Result.fail(:invalid_transition) unless OPEN.include?(tfd_case.status)

        tfd_case.update!({ appointment_at: time }.merge(provider ? { care_provider: provider } : {}))
        moved = Transition.call(tfd_case: tfd_case, to: nil, by: by, kind: "appointment_set")
        next moved if moved.failure?

        DomainEvents.publish("tfd.case_updated", tfd_case_id: tfd_case.id, user_id: by.id)
        moved
      end
    end

    # nil (mantém o do laudo) | CareProvider elegível (Tfd::Providers) | :invalid
    def provider(id) = id.nil? ? nil : (Providers.find(id) || :invalid)

    def parse(value)
      return nil unless value.is_a?(String) && value.match?(CareRegulation::ScheduleExternal::ZONED)

      DateTime.iso8601(value).to_time
    rescue Date::Error
      nil
    end
    private_class_method :provider, :parse
  end
end
