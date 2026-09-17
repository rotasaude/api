# Sessão do mantenedor (spec §6) — JSON-only, no host maintenance-api.*:
#
#   POST   /session            { email_address, password } → 200 { mfa_required, session_id }
#   POST   /session/challenge  { session_id, code }        → 200 mantenedor
#   GET    /session                                        → 200 mantenedor | 401
#   DELETE /session                                        → 204
module Maintenance
  class SessionsController < BaseController
    allow_unauthenticated_maintainer_access only: %i[create challenge_totp destroy]

    rate_limit to: 10, within: 3.minutes, only: %i[create challenge_totp],
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    # Custo constante: sem isto, e-mail desconhecido responde sem passar por
    # bcrypt e e-mail conhecido paga o hash — a diferença de tempo enumera
    # contas de superusuário. O digest de descarte é gerado uma vez, no boot.
    DUMMY_DIGEST = BCrypt::Password.create("rota-saude-dummy-password").freeze

    def create
      maintainer = Maintainer.active.find_by(email_address: params[:email_address].to_s.strip.downcase)

      unless maintainer
        dummy_authenticate
        return render(json: { error: "invalid_credentials" }, status: :unauthorized)
      end

      return render(json: { error: "locked" }, status: :unauthorized) if maintainer.locked?

      # Mantenedor conhecido, mas ainda sem convite aceito: não há digest para
      # comparar de verdade (authenticate nem chegaria a rodar bcrypt aqui), e o
      # custo do dummy o equipara ao caminho de senha errada abaixo. O
      # register_failed_password continua o mesmo de sempre — inclusive o
      # acúmulo de tentativas para conta não matriculada, que é intencional
      # nesta rodada (não é o achado desta correção).
      unless maintainer.enrolled?
        dummy_authenticate
        return register_failed_password(maintainer)
      end

      return register_failed_password(maintainer) unless maintainer.authenticate(params[:password].to_s)

      maintainer.clear_failures!
      session = start_pending_session_for(maintainer)
      render json: { mfa_required: true, session_id: session.id }, status: :ok
    end

    def challenge_totp
      session = pending_session
      return render(json: { error: "invalid_session" }, status: :unauthorized) unless session
      return register_failed_totp(session) unless Mfa::Verify.call(session.maintainer, code: params[:code])

      # Atômico, pelo mesmo motivo de Operators::SessionsController: o cookie já
      # foi plantado no passo da senha, então um carimbo sem evento de auditoria
      # autenticaria sem registro. O update_all condicional é a guarda contra a
      # corrida com register_failed_totp.
      now = Time.current
      verified = PlatformRecord.transaction do
        stamped = MaintainerSession.where(id: session.id, mfa_verified_at: nil)
                                   .update_all(mfa_verified_at: now, last_seen_at: now, updated_at: now)
        next false unless stamped == 1

        MaintenanceAudit.record("maintenance.session.started", outcome: "ok", module_name: "session",
                                maintainer_id: session.maintainer_id,
                                credential: MaintenanceAudit.credential_for(session: session))
        true
      end
      return render(json: { error: "invalid_session" }, status: :unauthorized) unless verified

      session.assign_attributes(mfa_verified_at: now, last_seen_at: now)
      write_maintenance_cookie(session)
      Current.maintainer_session = session
      render json: serialize(session), status: :ok
    end

    def show
      render json: serialize(Current.maintainer_session)
    end

    def destroy
      session = Current.maintainer_session || MaintainerSession.find_by(id: cookies.signed[MaintainerAuthentication::COOKIE])
      if session
        MaintenanceAudit.record("maintenance.session.ended", outcome: "ok", module_name: "session",
                                maintainer_id: session.maintainer_id,
                                credential: MaintenanceAudit.credential_for(session: session))
      end
      terminate_maintenance_session
      head :no_content
    end

    private

    # Roda o mesmo bcrypt que authenticate rodaria, contra um digest de
    # descarte, e joga o resultado fora — só o custo importa.
    def dummy_authenticate
      BCrypt::Password.new(DUMMY_DIGEST) == params[:password].to_s
    end

    # O bloqueio é da conta, não do IP: o rate_limit acima atrapalha quem insiste
    # do mesmo lugar, e trocar de IP é barato demais para ser a única barreira.
    def register_failed_password(maintainer)
      maintainer.register_failure!
      locked = maintainer.reload.locked?

      MaintenanceAudit.record(locked ? "maintenance.session.locked" : "maintenance.session.failed",
                              outcome: "rejected", module_name: "session", maintainer_id: maintainer.id,
                              credential: { "kind" => "password" })

      render json: { error: locked ? "locked" : "invalid_credentials" }, status: :unauthorized
    end

    # A sessão do challenge tem de ser a MESMA cujo cookie este cliente recebeu,
    # ainda pendente, dentro da janela e de mantenedor ativo.
    def pending_session
      id = params[:session_id].to_s
      return nil if id.empty? || cookies.signed[MaintainerAuthentication::COOKIE] != id

      session = MaintainerSession.find_by(id: id, mfa_verified_at: nil)
      return nil unless session
      return nil if session.created_at <= MaintainerAuthentication::PENDING_MFA_WINDOW.ago
      return nil unless session.maintainer.active?

      session
    end

    def register_failed_totp(session)
      counted = MaintainerSession.where(id: session.id, mfa_verified_at: nil)
                                 .update_all("totp_attempts = totp_attempts + 1")
      return render(json: { error: "invalid_session" }, status: :unauthorized) unless counted == 1

      attempts = MaintainerSession.where(id: session.id).pick(:totp_attempts)
      return render(json: { error: "invalid_code" }, status: :unauthorized) if
        attempts && attempts < MaintainerAuthentication::MAX_TOTP_ATTEMPTS

      MaintainerSession.where(id: session.id, mfa_verified_at: nil).delete_all
      cookies.delete(MaintainerAuthentication::COOKIE)
      MaintenanceAudit.record("maintenance.session.failed", outcome: "rejected", module_name: "session",
                              maintainer_id: session.maintainer_id, credential: { "kind" => "totp" })
      render json: { error: "too_many_attempts" }, status: :unauthorized
    end

    def serialize(session)
      maintainer = session.maintainer
      {
        id: maintainer.id,
        email_address: maintainer.email_address,
        mfa_verified_at: session.mfa_verified_at&.iso8601,
        expires_at: (session.mfa_verified_at + MaintainerAuthentication::ABSOLUTE_TTL).iso8601
      }
    end
  end
end
