# Entrega de e-mail com a mesma guarda de fila dos jobs do app (Plano 5): um
# deliver_later de mailer de cidade fora da conexão de uma cidade levanta
# PlatformQueue::Misplaced em vez de gravar o e-mail na fila de plataforma.
class CityMailDeliveryJob < ActionMailer::MailDeliveryJob
  # I1 (hardening review): ActiveJob::LogSubscriber loga "with arguments: ..."
  # em nível info para todo job com log_arguments? true (o default), sem
  # passar por filter_parameters. Os argumentos aqui são os do método do
  # mailer — para InvitationMailer, o e-mail e o accept_url com o token cru.
  # Desligado para este job nunca imprimir token/e-mail em log/STDOUT (rake,
  # console do worker).
  self.log_arguments = false

  before_enqueue { |job| PlatformQueue.check!(job) }
end
