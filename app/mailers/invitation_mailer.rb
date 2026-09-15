# Convite do primeiro municipal_admin de uma cidade recém-provisionada (Plano 4).
#
# Recebe SÓ valores simples (R42): deliver_later roda no worker, sem conexão de
# cidade. O ProvisionCityJob monta o endereço e o link.
class InvitationMailer < ApplicationMailer
  def invite(email_address:, accept_url:)
    @accept_url = accept_url
    mail(to: email_address, subject: "[rota-saúde] Convite para administrar sua cidade")
  end
end
