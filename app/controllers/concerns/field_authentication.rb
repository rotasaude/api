# Borda do app de campo (módulo 24b, ADR 0052; contrato §9.2; Q1, Q7), no padrão
# do Hl7::BaseController: host da cidade, sem cookie, `Authorization: Bearer
# rsf_…` (só o SHA-256 existe; o token nunca é lido da query nem do corpo).
# Ordem:
#   1. rate_limit 120/min por digest do token (por IP sem token), um balde só
#      para todo /field/v1 → 429 too_many_requests;
#   2. interruptor home_visits (HomeVisitsGate) → 403 feature_disabled;
#   3. o aparelho pelo índice único do digest: ausente/desconhecido → 401
#      invalid_token; revogado → 401 device_revoked. Em TODA requisição: usuário
#      ativo, papel health_professional e vínculo ativo da Tabela 7 em equipe
#      ativa 70/76 (HomeVisits::Access.device_owner?); sem isso o aparelho é
#      revogado agora (user_disabled | membership_ended) e a resposta é o mesmo
#      401 device_revoked, sem o motivo (Q7). Sempre WWW-Authenticate: Bearer;
#   4. last_used_at no máximo uma vez por minuto;
#   5. escrita só JSON (415 json_required) e corpo até 2 MB (413 payload_too_large).
# Nunca Current.session nem Current.user: o aparelho (@device), o dono
# (@device_user) e o vínculo (@device_member) vão como `by:` explícito (W-8).
module FieldAuthentication
  extend ActiveSupport::Concern

  # Avaliado no carregamento da classe: resolve Rails.cache a cada requisição
  # (mesmo molde do Hl7::BaseController), o que torna o teto exercitável em spec.
  module RateLimitStore
    def self.increment(...) = Rails.cache.increment(...)
  end

  WRITE_METHODS = %w[POST PUT PATCH DELETE].freeze

  included do
    include ::HomeVisitsGate

    rate_limit to: FieldSync::Catalog::RATE, within: 1.minute, name: "field_sync", scope: "field_sync", store: RateLimitStore,
               by: -> { bearer_token ? FieldDevice.digest(bearer_token) : request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }
    before_action :require_home_visits!
    before_action :authenticate_device!
    before_action :require_json_body!
  end

  private

  # Só o cabeçalho; nunca params (a query e o corpo não autenticam).
  def bearer_token
    header = request.authorization.to_s
    header.match?(/\ABearer /i) ? header.sub(/\ABearer /i, "").strip.presence : nil
  end

  # A busca é pelo SHA-256 (índice único; FieldDevice.by_token): o token em
  # claro nunca é comparado. Sem o vínculo de campo, revoga e responde o 401
  # uniforme.
  def authenticate_device!
    device = FieldDevice.by_token(bearer_token)
    return refuse_device("invalid_token") unless device
    return refuse_device("device_revoked") if device.revoked?

    user = device.user
    member = user.active? && HomeVisits::Access.device_owner?(user)
    unless member
      FieldDevices::Revoke.call(device, by: nil, reason: user.active? ? "membership_ended" : "user_disabled")
      return refuse_device("device_revoked")
    end

    @device = device
    @device_user = user
    @device_member = member
    touch_last_used!
  end

  def touch_last_used!
    return if @device.last_used_at && @device.last_used_at > FieldSync::Catalog::LAST_USED_EVERY.ago

    @device.update_columns(last_used_at: Time.current)
  end

  def refuse_device(error)
    response.headers["WWW-Authenticate"] = "Bearer"
    render json: { error: error }, status: :unauthorized
  end

  def require_json_body!
    return unless WRITE_METHODS.include?(request.request_method)
    return render(json: { error: "json_required" }, status: :unsupported_media_type) unless request.media_type == "application/json"

    render json: { error: "payload_too_large" }, status: 413 if body_too_large?
  end

  # Content-Length declarado; sem ele (chunked), lê no máximo o teto + 1 byte.
  def body_too_large?
    limit = FieldSync::Catalog::MAX_BODY_BYTES
    return request.content_length > limit if request.content_length

    chunk = request.body.read(limit + 1)
    request.body.rewind
    chunk.to_s.bytesize > limit
  end
end
