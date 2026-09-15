class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "rota-saude@example.com")
  layout "mailer"

  # deliver_later passa pela guarda de fila (PlatformQueue, Plano 5).
  self.delivery_job = CityMailDeliveryJob
end
