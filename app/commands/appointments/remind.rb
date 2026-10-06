# Lembrete da véspera do horário confirmado (ADR 0029 §6). Sob lock do
# horário: um aviso na caixa do cidadão (sempre), um SMS de texto fixo (só com
# a chave de SMS da cidade, provedor, opt-in e sem o opt-out de lembretes,
# dentro da janela 8h–20h) e reminded_at (idempotência). Falha do provedor não
# repete; o log leva só a classe do erro. Só a chamada ao provedor é
# resgatada (como no lembrete de confirmação): erro de banco segue adiante e
# desfaz tudo, e a próxima rodada tenta de novo.
module Appointments
  module Remind
    TEXT = "Secretaria de Saúde de %{city}: você tem um compromisso de saúde amanhã. Veja em %{link}".freeze

    module_function

    def call(appointment:, now: Time.current)
      ApplicationRecord.transaction do
        # Ordem global (cidadão → horário): o aviso tem FK para o cidadão, e a
        # exclusão (Citizens::Erase) segura o cidadão em FOR UPDATE antes de
        # travar o horário. Pegar o KEY SHARE só depois do horário cruzava as
        # duas (deadlock). citizen_id do horário nunca muda (trigger).
        Citizen.lock("FOR KEY SHARE").find(appointment.citizen_id)
        appointment.lock!
        next Result.ok(skipped: :not_due) unless appointment.status == "confirmed" && appointment.reminded_at.nil?

        unless AppointmentNotice.exists?(appointment_id: appointment.id)
          AppointmentNotice.create!(appointment: appointment, citizen_id: appointment.citizen_id, created_at: now)
        end
        sms = sms_allowed?(appointment, now) && deliver(appointment)
        appointment.update!(reminded_at: now)
        DomainEvents.publish("appointment.reminded", appointment_id: appointment.id, sms: sms)
        Result.ok(sms: sms)
      end
    end

    def sms_allowed?(appointment, now)
      return false unless Campaigns::SmsSetting.enabled? && SmsGateway.configured?
      return false unless Campaigns::SmsBatchJob::WINDOW_HOURS.cover?(now.hour)

      preference = CitizenContactPreference.find_by(citizen_id: appointment.citizen_id)
      preference.present? && preference.sms_opt_in && !preference.appointment_reminders_muted
    end

    # Só o provedor é resgatado. O provedor real ainda não existe (go-live), e
    # o SmsGateway só declara Unavailable: qualquer outro erro dele também
    # conta como falha de entrega — menos erro de banco, que segue adiante.
    def deliver(appointment)
      SmsGateway.deliver(phone: appointment.citizen.phone, body: body)
      true
    rescue ActiveRecord::ActiveRecordError
      raise
    rescue StandardError => e
      Rails.logger.warn("[appointment.reminded] SMS não saiu: #{e.class}")
      false
    end

    def body
      name = CityProfile.current&.name.presence || Current.city.name
      format(TEXT, city: name, link: Campaigns::SmsText.link(Current.city))
    end
  end
end
