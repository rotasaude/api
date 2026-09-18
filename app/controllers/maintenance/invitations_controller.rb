# Aceite do convite de mantenedor (spec §6), em dois passos:
#
#   POST /invitations/enroll   { token } → gera o TOTP e devolve o material de
#                                          cadastro (uri e secret; NÃO há
#                                          recovery code — spec §6)
#   POST /invitations/accept   { token, password, code } → só aqui a conta
#                                          passa a logar, e o convite é consumido
#
# Sem autenticação, por definição: quem aceita ainda não tem sessão. O que
# protege é o token de uso único, com 24h de validade, guardado só como digest.
#
# POST nos dois, com o token no CORPO (fix round 1): um GET com o token no path
# aparece em claro no log de acesso — "Started GET /invitations/<token>" — e
# `filter_parameters` só filtra query string e corpo, nunca o path. Staging é
# público e este token define senha e TOTP de um superusuário.
module Maintenance
  class InvitationsController < BaseController
    allow_unauthenticated_maintainer_access

    rate_limit to: 10, within: 3.minutes,
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def enroll
      invitation = usable_invitation or return head(:not_found)

      # C1: `recovery_codes: false`. Spec §6 — "Não há recovery codes"; a
      # recuperação é outro mantenedor reenviar o convite, que zera senha, TOTP
      # e sessões. Um código de recuperação seria um segundo fator estático e
      # permanente numa conta de poder total.
      enrollment = Mfa::Enroll.call(invitation.maintainer, recovery_codes: false)

      # I4: este POST ROTACIONA o otp_secret de um superusuário. Sem auditoria,
      # a troca do segundo fator é o único ato desta superfície que não deixa
      # rastro. O id do convite entra para amarrar a rotação ao convite que a
      # autorizou.
      MaintenanceAudit.record("maintenance.maintainer.enrolled", outcome: "ok", module_name: "maintainer",
                              maintainer_id: invitation.maintainer_id,
                              credential: { "kind" => "invitation" }, invitation_id: invitation.id,
                              **audit_request_fields)

      render json: {
        email_address: invitation.maintainer.email_address,
        otpauth_uri: enrollment[:otpauth_uri],
        secret: enrollment[:secret]
      }, status: :ok
    end

    def accept
      invitation = usable_invitation or return head(:not_found)
      maintainer = invitation.maintainer

      password = params[:password].to_s
      return render(json: { error: "weak_password" }, status: :unprocessable_content) if password.length < 12

      # C1: `totp_valid?`, nunca `Mfa::Verify.call` — `call` cai no recovery
      # code quando o TOTP não bate, e aqui não existe recovery code. Com
      # `call`, um código de recuperação sobrevivente (conta antiga, linha
      # plantada) matricularia a conta sem TOTP nenhum.
      accepted = PlatformRecord.transaction do
        # I3: consome o passo, pelo mesmo motivo do challenge — este código
        # confirma o TOTP recém-cadastrado e não pode servir duas vezes.
        raise ActiveRecord::Rollback unless maintainer.consume_totp!(params[:code])

        maintainer.update!(password: password, otp_enabled_at: Time.current)
        invitation.update!(used_at: Time.current)
        # Convite é EXCLUSIVO (fix round 1): aceitar este invalida qualquer
        # outro ainda pendente do mesmo mantenedor.
        MaintainerInvitation.invalidate_pending_for!(maintainer)
        MaintenanceAudit.record("maintenance.maintainer.accepted", outcome: "ok", module_name: "maintainer",
                                maintainer_id: maintainer.id, credential: { "kind" => "invitation" },
                                **audit_request_fields)
        true
      end

      unless accepted
        # I4: o aceite recusado também é registro de auditoria — é a tentativa
        # de tomar a conta com o token na mão.
        MaintenanceAudit.record("maintenance.maintainer.accepted", outcome: "rejected", module_name: "maintainer",
                                maintainer_id: maintainer.id, credential: { "kind" => "invitation" },
                                invitation_id: invitation.id, **audit_request_fields)
        return render(json: { error: "invalid_code" }, status: :unprocessable_content)
      end

      head :no_content
    end

    private

    # Busca pelo DIGEST: o token em claro nunca foi gravado. Convite usado,
    # vencido, inexistente ou de conta desativada respondem igual — 404 — para
    # não distinguir "não existe" de "já usado".
    def usable_invitation
      invitation = MaintainerInvitation.find_by(token_digest: MaintainerInvitation.digest_for(params[:token]))
      return nil unless invitation&.usable?
      return nil unless invitation.maintainer.active?

      invitation
    end
  end
end
