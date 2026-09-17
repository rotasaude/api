# Aceite do convite de mantenedor (spec §6), em dois passos:
#
#   GET  /invitations/:token          → gera o TOTP e devolve o material de
#                                       cadastro (uri, secret, recovery codes)
#   POST /invitations/:token/accept   → senha + código; só aqui a conta passa a
#                                       logar, e o convite é consumido
#
# Sem autenticação, por definição: quem aceita ainda não tem sessão. O que
# protege é o token de uso único, com 24h de validade, guardado só como digest.
module Maintenance
  class InvitationsController < BaseController
    allow_unauthenticated_maintainer_access

    rate_limit to: 10, within: 3.minutes,
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def show
      invitation = usable_invitation or return head(:not_found)

      enrollment = Mfa::Enroll.call(invitation.maintainer)
      render json: {
        email_address: invitation.maintainer.email_address,
        otpauth_uri: enrollment[:otpauth_uri],
        secret: enrollment[:secret],
        recovery_codes: enrollment[:recovery_codes]
      }, status: :ok
    end

    def accept
      invitation = usable_invitation or return head(:not_found)
      maintainer = invitation.maintainer

      password = params[:password].to_s
      return render(json: { error: "weak_password" }, status: :unprocessable_content) if password.length < 12
      unless Mfa::Verify.call(maintainer, code: params[:code])
        return render(json: { error: "invalid_code" }, status: :unprocessable_content)
      end

      PlatformRecord.transaction do
        maintainer.update!(password: password, otp_enabled_at: Time.current)
        invitation.update!(used_at: Time.current)
        MaintenanceAudit.record("maintenance.maintainer.accepted", outcome: "ok", module_name: "maintainer",
                                maintainer_id: maintainer.id, credential: { "kind" => "invitation" })
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
