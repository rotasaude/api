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
# M2 (rodada de hardening, review): city:invite_admin só existe para reenviar
# o convite do PRIMEIRO admin travado — uma cidade que já tem um
# municipal_admin ativo já passou do onboarding; reenviar aqui criaria um
# segundo convite de admin, não-relacionado, em vez de retomar um travado.
# Recusa e não escreve nada.
#
# M1 (rodada de hardening, review): duas execuções concorrentes (duas rakes, ou
# uma rake correndo junto de um retry do ProvisionCityJob) não podem criar dois
# convites PENDENTES pro mesmo email/role — antes disso, find-then-create sem
# trava deixava as duas passarem pela checagem "existe pendente?" antes de
# qualquer uma criar. A trava é pg_advisory_xact_lock, escopada à transação
# (liberada sozinha no commit OU rollback, sem unlock explícito), chaveada por
# hashtext(email:role) — a menor mecânica que resolve, sem precisar de uma
# constraint de unicidade nova no schema de cidade.
#
# M3 (rodada de hardening final): pg_advisory_xact_lock devolve void, e
# select_value tentava tipar esse retorno — logava "unknown OID 2278" em toda
# chamada. Trocado por connection.execute (mesmo bind/quote da key), que só
# roda a instrução sem tentar ler um valor de volta.
#
# M4 (rodada de hardening final): a checagem "já existe municipal_admin
# ativo?" (M2) agora roda DEPOIS de tomar a trava, não antes — checar fora da
# seção travada lia esse estado sem nenhuma garantia de que ele seguiria
# valendo até a criação do convite, alguns passos depois. Dentro da seção
# travada, a leitura fica próxima o bastante do efeito que ela guarda.
#
# Devolve só os argumentos PLANOS do e-mail (R42: mailers recebem string, nunca
# AR object) e o id do convite (uuid não-PII, só para auditoria) dentro de
# Result — nunca a Invitation nem o token soltos, para nenhum chamador logar o
# token por engano. Quem chama enfileira InvitationMailer FORA de
# CityConnection.with e fora de qualquer transação — a fila de destino é
# decidida no commit mais de fora (ver app/services/platform_queue.rb).
module CityLifecycle
  module InviteAdmin
    def self.call(city:, email:)
      invitation = nil
      failure = nil

      Current.set(city: city) do
        CityConnection.with(city) do
          ApplicationRecord.transaction do
            lock_key = "#{email.downcase}:municipal_admin"
            ApplicationRecord.connection.execute(
              "SELECT pg_advisory_xact_lock(hashtext(#{ApplicationRecord.connection.quote(lock_key)}))"
            )

            if Membership.active.exists?(role: "municipal_admin")
              failure = Result.fail(:admin_exists,
                message: "cidade #{city.slug} já tem um municipal_admin ativo — invite_admin só reenvia " \
                         "o convite do primeiro admin")
              raise ActiveRecord::Rollback
            end

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
      end

      return Result.fail(failure.reason, message: failure.message) if failure

      Result.ok(
        mail_args: { email_address: email, accept_url: CityDashboardUrl.invitation(city, token: invitation.token) },
        invitation_id: invitation.id
      )
    end
  end
end
