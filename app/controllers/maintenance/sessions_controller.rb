# Sessão do mantenedor (spec §6) — JSON-only, no host maintenance-api.*:
#
#   POST   /session            { email_address, password } → 200 { mfa_required, session_id }
#   POST   /session/challenge  { session_id, code }        → 200 mantenedor
#   GET    /session                                        → 200 mantenedor | 401
#   DELETE /session                                        → 204
module Maintenance
  class SessionsController < BaseController
    allow_unauthenticated_maintainer_access only: %i[create challenge_totp destroy]

    # Fix round 1 (I3): estes endpoints são do NAVEGADOR — cookie, TOTP,
    # bloqueio por conta. Um token de serviço se identifica pela query
    # GraphQL `me`, nunca por aqui; `show` lia `Current.maintainer_session`, que
    # um token nunca define, e estourava NoMethodError. Roda em TODA ação,
    # inclusive as que dispensam `require_maintainer_authentication` — um
    # bearer não vira sessão de navegador só porque a ação é pública.
    before_action :require_browser_credential

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

      # I2: conta bloqueada responde IGUAL a credencial inválida — "locked"
      # confirmava, para qualquer um, que aquele e-mail é de um mantenedor. E
      # paga o mesmo bcrypt (I2/5592ad2): sem o dummy, este retorno antecipado
      # era o caminho mais rápido da controller e denunciava a conta pelo tempo.
      # I5: a tentativa contra conta bloqueada era o único caminho sem
      # auditoria nenhuma — justamente o de quem está insistindo. Não incrementa
      # o contador: renovar o bloqueio a cada tentativa o tornaria eterno.
      if maintainer.locked?
        dummy_authenticate
        MaintenanceAudit.record("maintenance.session.failed", outcome: "rejected", module_name: "session",
                                maintainer_id: maintainer.id, credential: { "kind" => "password" })
        return render(json: { error: "invalid_credentials" }, status: :unauthorized)
      end

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

      # C2: a contagem NÃO zera aqui. Zerar no passo da senha devolvia ao
      # atacante que já tem a senha um contador limpo a cada nova sessão
      # pendente — quatro palpites de TOTP por sessão, para sempre, sem nunca
      # bloquear. A contagem zera quando a autenticação se COMPLETA (o TOTP
      # certo, em challenge_totp).
      session = start_pending_session_for(maintainer)
      render json: { mfa_required: true, session_id: session.id }, status: :ok
    end

    def challenge_totp
      session = pending_session
      return render(json: { error: "invalid_session" }, status: :unauthorized) unless session
      # C1: TOTP e nada mais. `Mfa::Verify.call` aceitaria um recovery code no
      # lugar do código — um segundo fator estático para a conta de maior poder
      # do sistema.
      #
      # I3 (fix round 2): `consume_totp!`, não `totp_valid?` — o código é
      # CONSUMIDO aqui. Sem isso, o mesmo código ainda emitia um token de 90
      # dias no step-up de `createMaintenanceToken`, segundos depois. Um código
      # repetido conta como falha, como qualquer código que não serve.
      return register_failed_totp(session) unless session.maintainer.consume_totp!(params[:code])

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

      # Autenticação completa: só agora a sequência de falhas foi quebrada.
      session.maintainer.clear_failures!
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

    def require_browser_credential
      return unless Current.maintenance_credential&.token?

      render json: { error: "browser_only" }, status: :forbidden
    end

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

      # I2: a resposta é a mesma bloqueado ou não. O bloqueio continua valendo
      # (o retorno antecipado lá em cima), só não é anunciado.
      render json: { error: "invalid_credentials" }, status: :unauthorized
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

      # C2/I5: um bloqueio que cai ENTRE o passo da senha e o challenge tem de
      # valer aqui — senão a sessão pendente vira uma janela em que a conta
      # bloqueada ainda pode ser aberta. E a tentativa é auditada: ela é a
      # única prova de que alguém continuou tentando com a conta travada.
      if session.maintainer.locked?
        MaintenanceAudit.record("maintenance.session.failed", outcome: "rejected", module_name: "session",
                                maintainer_id: session.maintainer_id, credential: { "kind" => "totp" })
        return nil
      end

      session
    end

    # C2: o contador da SESSÃO sozinho não protege nada — quem tem a senha abre
    # uma sessão pendente nova a cada cinco palpites e recomeça, para sempre. O
    # TOTP errado agora conta para o bloqueio da CONTA, como a senha errada
    # (spec §6: "cinco falhas seguidas na conta — senha ou TOTP").
    # I5: e cada falha é auditada, não só a quinta.
    def register_failed_totp(session)
      counted = MaintainerSession.where(id: session.id, mfa_verified_at: nil)
                                 .update_all("totp_attempts = totp_attempts + 1")
      return render(json: { error: "invalid_session" }, status: :unauthorized) unless counted == 1

      maintainer = session.maintainer
      maintainer.register_failure!
      locked = maintainer.reload.locked?

      MaintenanceAudit.record(locked ? "maintenance.session.locked" : "maintenance.session.failed",
                              outcome: "rejected", module_name: "session",
                              maintainer_id: session.maintainer_id, credential: { "kind" => "totp" })

      attempts = MaintainerSession.where(id: session.id).pick(:totp_attempts)
      over_cap = attempts.nil? || attempts >= MaintainerAuthentication::MAX_TOTP_ATTEMPTS
      return render(json: { error: "invalid_code" }, status: :unauthorized) unless locked || over_cap

      # Sessão pendente de conta bloqueada não sobrevive: sem isto o bloqueio
      # deixaria de pé exatamente a sessão que estava sendo atacada.
      MaintainerSession.where(id: session.id, mfa_verified_at: nil).delete_all
      cookies.delete(MaintainerAuthentication::COOKIE)
      render json: { error: over_cap ? "too_many_attempts" : "invalid_code" }, status: :unauthorized
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
