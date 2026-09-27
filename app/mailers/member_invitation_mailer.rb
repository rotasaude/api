# Convite de membro da equipe da cidade (F-06.9), feito pelo municipal_admin em
# POST /setup/invitations. Mailer DE CIDADE: vai para a fila da cidade, ao lado
# do user.invited — InvitationMailer é o do primeiro admin, na fila de
# plataforma (PlatformQueue::MAILERS), e não entra na fila de uma cidade.
#
# Recebe SÓ valores simples (R42). O SetupController monta o endereço e o link.
class MemberInvitationMailer < ApplicationMailer
  def invite(email_address:, accept_url:)
    @accept_url = accept_url
    mail(to: email_address, subject: "[rota-saúde] Convite para a equipe da sua cidade")
  end
end
