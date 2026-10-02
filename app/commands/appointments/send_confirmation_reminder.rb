# Lembrete de confirmação (api#39; ADR 0019, Revisão 2026-10-02): um SMS 24h
# antes do prazo, só para horário ainda sem confirmação. É mensagem do próprio
# atendimento: não exige o opt-in das campanhas, mas respeita o opt-out de
# lembretes. Sem a chave de SMS da cidade ou sem provedor, nada sai e o
# resultado fica registrado (disabled / unavailable). Sob lock do horário:
# o cidadão que confirma ao mesmo tempo não recebe o SMS.
module Appointments
  class SendConfirmationReminder
    LEAD = 24.hours # antes do prazo de confirmação

    def self.due(now)
      Appointment.where(status: "scheduled")
                 .where(confirmation_deadline_at: (now + 1.second)..(now + LEAD))
                 .where.not(id: AppointmentReminder.select(:appointment_id))
    end

    def self.call(appointment:, now: Time.current)
      ApplicationRecord.transaction do
        appointment.lock!
        next Result.ok(skipped: true) unless appointment.status == "scheduled"
        next Result.ok(skipped: true) if AppointmentReminder.exists?(appointment_id: appointment.id)

        status, error = deliver(appointment)
        AppointmentReminder.create!(appointment: appointment, status: status, error: error, created_at: now)
        DomainEvents.publish("appointment.reminder_recorded", appointment_id: appointment.id,
                                                              appointment_request_id: appointment.request_id,
                                                              status: status)
        Result.ok(status: status)
      end
    end

    def self.deliver(appointment)
      return [ "opted_out", nil ] if CitizenContactPreference.find_by(citizen_id: appointment.citizen_id)
                                                             &.appointment_reminders_muted
      return [ "disabled", nil ] unless Campaigns::SmsSetting.enabled?
      return [ "unavailable", nil ] unless SmsGateway.configured?

      SmsGateway.deliver(phone: appointment.citizen.phone, body: body)
      [ "sent", nil ]
    rescue SmsGateway::Unavailable
      [ "unavailable", nil ]
    rescue StandardError => e
      # Só a classe: a mensagem do provedor pode ter o telefone.
      [ "failed", e.class.name.truncate(200) ]
    end

    # Texto fixo (como o SMS das campanhas, ADR 0024 D6): aparece na tela de
    # bloqueio, então não leva unidade, data, motivo nem identificador.
    def self.body
      name = CityProfile.current&.name.presence || Current.city.name
      "Secretaria de Saúde de #{name}: você tem um horário para confirmar. Acesse #{CityPublicUrl.wpda(Current.city)}"
    end
  end
end
