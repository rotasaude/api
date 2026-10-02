# Lembretes de confirmação de horário (api#39), cidade por cidade. Só dentro
# das 8h–20h no fuso da cidade (a mesma janela do SMS das campanhas): fora
# dela não faz nada, e a próxima execução dentro da janela pega o que venceu.
# O prazo fica pelo menos 24h à frente de quando o horário é marcado, então
# sempre sobra janela antes dele.
class SendConfirmationRemindersJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  def perform
    now = Time.current
    return unless Campaigns::SmsBatchJob::WINDOW_HOURS.cover?(now.hour)

    Appointments::SendConfirmationReminder.due(now).find_each do |appointment|
      Appointments::SendConfirmationReminder.call(appointment: appointment, now: now)
    end
  end
end
