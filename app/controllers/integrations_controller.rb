# app/controllers/integrations_controller.rb
# Integrações da cidade (ADR 0028; contratos §5.1): estado, cadastro/troca de
# credencial (step-up) e teste de conexão. Só municipal_admin. Nenhuma
# resposta devolve segredo.
class IntegrationsController < ApplicationController
  include Authentication
  include MfaStepUp

  wrap_parameters false

  ERROR_STATUS = { unknown_kind: :unprocessable_entity, invalid_credential: :unprocessable_entity,
                   credential_missing: :conflict }.freeze

  before_action :require_admin

  def show
    city = Current.city
    settings = Platform::Features.settings(city)
    state = Platform::Features.city_state(city)
    credentials = IntegrationCredential.includes(:set_by_user).index_by(&:kind)
    render json: {
      record_mode: settings[:record_mode], pec_url_set: settings[:pec_url].present?,
      ibge_code_set: state&.dig(:ibge_code).present?,
      credentials: IntegrationCredential::KINDS.map { |kind| credential_json(kind, credentials[kind]) },
      features: Platform::Features.summary(city, state: state).map { |f| f.slice(:key, :enabled, :usable, :missing) }
    }
  end

  def update
    return render_error(:unknown_kind) unless IntegrationCredential::KINDS.include?(params[:kind])
    return require_step_up! unless reauthenticated_recently?

    body = request.request_parameters
    result = Integrations::SetCredential.call(kind: params[:kind], username: body["username"],
                                              password: body["password"], by: Current.user)
    return render_error(result.reason) if result.failure?

    render json: credential_json(params[:kind], result.payload[:credential])
  end

  def check
    result = Integrations::CheckConnection.call(kind: params[:kind], city: Current.city)
    return render_error(result.reason) if result.failure?

    render json: credential_json(params[:kind], result.payload[:credential])
  end

  private

  def require_admin
    render json: { error: "missing_role" }, status: :forbidden unless IntegrationPolicy.new(Current.user, nil).manage?
  end

  def render_error(reason)
    render json: { error: reason.to_s }, status: ERROR_STATUS.fetch(reason, :unprocessable_entity)
  end

  def credential_json(kind, credential)
    {
      kind: kind, set: !credential.nil?, set_at: credential&.set_at&.iso8601,
      set_by: credential&.set_by_user&.email_address, last_check_at: credential&.last_check_at&.iso8601,
      last_check_status: credential&.last_check_status, last_check_message: credential&.last_check_message
    }
  end
end
