# Sessão de operador no console de plataforma — JSON-only. Ver ADR-0011.
#
# Mesmos caminhos e mesmo formato de resposta da sessão da cidade, servidos só
# no host admin.* (config/routes.rb, PlatformConsoleHost):
#
#   POST   /session            { email_address, password } → 200 { mfa_required, session_id }
#   POST   /session/challenge  { session_id, code }        → 200 operador
#   GET    /session                                        → 200 operador | 401
#   DELETE /session                                        → 204
module Operators
  class SessionsController < BaseController
    allow_unauthenticated_operator_access only: %i[create challenge_totp]

    rate_limit to: 10, within: 3.minutes, only: %i[create challenge_totp],
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      operator = authenticate_operator(params[:email_address], params[:password])
      return render(json: { error: "invalid_credentials" }, status: :unauthorized) unless operator
      return render(json: { error: "mfa_enrollment_required" }, status: :forbidden) unless operator.mfa_enrolled?

      session = start_pending_operator_session_for(operator)
      render json: { mfa_required: true, session_id: session.id }, status: :ok
    end

    def challenge_totp
      session = pending_session
      return render(json: { error: "invalid_session" }, status: :unauthorized) unless session

      unless Mfa::Verify.call(session.operator, code: params[:code])
        return render(json: { error: "invalid_code" }, status: :unauthorized)
      end

      # Atomic: se Platform.audit falhar depois de carimbar mfa_verified_at, o
      # cookie já plantado no passo da senha autenticaria sem nenhum
      # PlatformEvent registrado. Um só transaction faz os dois comitarem ou
      # nenhum.
      PlatformRecord.transaction do
        session.update!(mfa_verified_at: Time.current)
        Platform.audit("operator.login", operator_id: session.operator_id, operator_session_id: session.id)
      end
      write_operator_cookie(session)
      Current.operator_session = session
      render json: serialize(session), status: :ok
    end

    def show
      render json: serialize(Current.operator_session)
    end

    def destroy
      terminate_operator_session
      head :no_content
    end

    private

    def authenticate_operator(email, password)
      return nil if email.blank? || password.blank?

      operator = Operator.find_by(email_address: email)
      return nil unless operator&.active?

      operator.authenticate(password) || nil
    end

    # A sessão do challenge tem de ser a MESMA cujo cookie este cliente recebeu no
    # passo da senha, ainda sem TOTP, dentro da janela e de operador ativo. Sem o
    # vínculo com o cookie, quem soubesse um session_id pendente de outro
    # operador poderia completar o login dele com um TOTP próprio.
    def pending_session
      id = params[:session_id].to_s
      return nil if id.empty? || cookies.signed[OperatorAuthentication::COOKIE] != id

      session = OperatorSession.find_by(id: id, mfa_verified_at: nil)
      return nil unless session
      return nil if session.created_at <= OperatorAuthentication::PENDING_MFA_WINDOW.ago
      return nil unless session.operator.active?

      session
    end

    # Mesmo formato do SessionUser que o frontend do admin já lê.
    def serialize(session)
      operator = session.operator
      {
        id: operator.id,
        email_address: operator.email_address,
        mfa_enrolled: operator.mfa_enrolled?,
        operator: true,
        mfa_verified_at: session.mfa_verified_at&.iso8601,
        memberships: []
      }
    end
  end
end
