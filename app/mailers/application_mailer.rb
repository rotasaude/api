class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "rota-saude@example.com")
  layout "mailer"
end
