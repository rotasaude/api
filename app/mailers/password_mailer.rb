# E-mail de redefinição de senha (F-06.2, ADR-0011). O token expira em 15 min e
# é de uso único.
#
# Recebe SÓ valores simples (R42): deliver_later roda no worker sem conexão de
# cidade, onde um User (GlobalID) não desserializa. O PasswordsController monta
# o endereço e o link (no host da cidade) dentro da requisição.
class PasswordMailer < ApplicationMailer
  def reset(email_address:, reset_url:)
    @reset_url = reset_url
    mail(to: email_address, subject: "[rota-saúde] Redefinição de senha")
  end
end
