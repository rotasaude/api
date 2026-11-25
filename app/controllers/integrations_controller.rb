# app/controllers/integrations_controller.rb
# Integrações da cidade (ADR 0028; contratos §5.1): estado, cadastro/troca de
# credencial (step-up) e teste de conexão. Só municipal_admin. Nenhuma
# resposta devolve segredo.
class IntegrationsController < ApplicationController
  include Authentication
  include MfaStepUp

  wrap_parameters false

  ERROR_STATUS = { unknown_kind: :unprocessable_entity, invalid_credential: :unprocessable_entity,
                   invalid_certificate: :unprocessable_entity, certificate_expired: :unprocessable_entity,
                   invalid_requester_cnes: :unprocessable_entity, invalid_environment: :unprocessable_entity,
                   environment_not_allowed: :unprocessable_entity,
                   credential_missing: :conflict }.freeze

  before_action :require_admin

  def show
    city = Current.city
    settings = Platform::Features.settings(city)
    state = Platform::Features.city_state(city)
    credentials = IntegrationCredential.includes(:set_by_user).in_use(Bnafar::Environment.current).index_by(&:kind)
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

    secret = request.request_parameters.slice(*IntegrationCredential::SECRET_KEYS.fetch(params[:kind]))
    result = Integrations::SetCredential.call(kind: params[:kind], secret: secret, by: Current.user, city: Current.city,
                                              environment: requested_environment)
    return render_error(result.reason) if result.failure?

    render json: credential_json(params[:kind], result.payload[:credential])
  end

  def check
    result = Integrations::CheckConnection.call(kind: params[:kind], city: Current.city)
    return render_error(result.reason) if result.failure?

    render json: credential_json(params[:kind], result.payload[:credential])
  end

  private

  # `environment` só vale para a bnafar (Q9); nos outros tipos é ignorado.
  def requested_environment
    return "production" unless params[:kind] == "bnafar"

    value = request.request_parameters["environment"]
    value.nil? ? "production" : value
  end

  def require_admin
    render json: { error: "missing_role" }, status: :forbidden unless IntegrationPolicy.new(Current.user, nil).manage?
  end

  def render_error(reason)
    render json: { error: reason.to_s }, status: ERROR_STATUS.fetch(reason, :unprocessable_entity)
  end

  def credential_json(kind, credential)
    {
      kind: kind, environment: credential&.environment || (kind == "bnafar" ? Bnafar::Environment.current : "production"),
      set: !credential.nil?, set_at: credential&.set_at&.iso8601,
      set_by: credential&.set_by_user&.email_address, last_check_at: credential&.last_check_at&.iso8601,
      last_check_status: credential&.last_check_status, last_check_message: credential&.last_check_message
    }
  end
end
