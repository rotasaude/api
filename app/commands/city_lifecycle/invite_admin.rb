# Convite (ou reconvite) do primeiro municipal_admin de uma cidade — extraído
# do ProvisionCityJob (rodada de hardening, pre-Plano 6) para ser chamado por
# dois lugares:
#   - ProvisionCityJob#seed, na fase 2 do provisionamento (cidade ainda
#     provisioning): cria o primeiro convite, ou reenvia o mesmo token
#     PENDENTE num retry;
#   - rake city:invite_admin, para uma cidade JÁ active cujo primeiro admin
#     perdeu a janela de 7 dias do convite original — o guard no início de
#     ProvisionCityJob#perform só reenvia enquanto a cidade segue provisioning.
#
# Convite vencido ou aceito não é reaproveitado: nasce um novo (mesma regra que
# valia dentro do job antes desta extração).
#
# Devolve só os argumentos PLANOS do e-mail (R42: mailers recebem string, nunca
# AR object) dentro de Result — nunca a Invitation nem o token soltos, para
# nenhum chamador logar o token por engano. Quem chama enfileira
# InvitationMailer FORA de CityConnection.with e fora de qualquer transação —
# a fila de destino é decidida no commit mais de fora (ver
# app/services/platform_queue.rb).
module CityLifecycle
  module InviteAdmin
    def self.call(city:, email:)
      invitation = nil
      failure = nil

      Current.set(city: city) do
        CityConnection.with(city) do
          invitation = Invitation.pending.find_by(email: email.downcase, role: "municipal_admin")
          next if invitation

          invited = InviteMember.call(email: email, role: "municipal_admin", invited_by: nil)
          if invited.failure?
            failure = invited
          else
            invitation = invited.payload[:invitation]
          end
        end
      end

      return Result.fail(failure.reason, message: failure.message) if failure

      Result.ok(mail_args: { email_address: email, accept_url: CityDashboardUrl.invitation(city, token: invitation.token) })
    end
  end
end
