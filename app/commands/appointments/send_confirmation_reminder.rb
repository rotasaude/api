# Lembrete de confirmação (api#39): um SMS 24h antes do prazo, só para horário
# ainda sem confirmação. É mensagem do próprio atendimento: não exige o opt-in
# das campanhas, mas respeita o opt-out de lembretes.
#
# O lembrete só se gasta quando o provedor responde: `sent`, ou `failed` (erro
# do provedor, sem nova tentativa, para não insistir num número que recusa).
# Opt-out, chave de SMS da cidade desligada ou sem provedor não gravam nada:
# o próximo run dentro da janela tenta de novo até o prazo, então ligar o SMS
# ou reativar o lembrete a tempo ainda alcança o cidadão.
#
# Sob lock do horário: o cidadão que confirma ao mesmo tempo não recebe o SMS.
# O SMS sai dentro da transação, como no lote das campanhas: no go-live, o
# provedor precisa de timeout curto (segura o lock do horário).
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
        next Result.ok(skipped: :not_scheduled) unless appointment.status == "scheduled"
        next Result.ok(skipped: :already_sent) if AppointmentReminder.exists?(appointment_id: appointment.id)
        next Result.ok(skipped: :opted_out) if muted?(appointment)
        next Result.ok(skipped: :disabled) unless Campaigns::SmsSetting.enabled?
        next Result.ok(skipped: :unavailable) unless SmsGateway.configured?

        status, error = deliver(appointment)
        next Result.ok(skipped: :unavailable) if status == "unavailable"

        AppointmentReminder.create!(appointment: appointment, status: status, error: error, created_at: now)
        DomainEvents.publish("appointment.reminder_recorded", appointment_id: appointment.id,
                                                              appointment_request_id: appointment.request_id,
                                                              status: status)
        Result.ok(status: status)
      end
    end

    def self.muted?(appointment)
      CitizenContactPreference.find_by(citizen_id: appointment.citizen_id)&.appointment_reminders_muted == true
    end

    # Só a chamada ao provedor é resgatada; erro de banco segue adiante.
    def self.deliver(appointment)
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
