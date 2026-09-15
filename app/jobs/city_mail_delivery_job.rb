# Entrega de e-mail com a mesma guarda de fila dos jobs do app (Plano 5): um
# deliver_later de mailer de cidade fora da conexão de uma cidade levanta
# PlatformQueue::Misplaced em vez de gravar o e-mail na fila de plataforma.
class CityMailDeliveryJob < ActionMailer::MailDeliveryJob
  before_enqueue { |job| PlatformQueue.check!(job) }
end
