# Base das rotas /pharmacy/* (ADR 0045): sessão do dashboard e `pharmacy`
# ligado (403 feature_disabled). Dado do paciente (CPF, CNS, nome, medicamento,
# número de notificação, motivo) só do corpo JSON, nunca da URL.
module Pharmacy
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::PharmacyGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422.
    FAILURE_STATUS = { already_received: :conflict, opening_exists: :conflict, location_has_stock: :conflict,
                       location_inactive: :conflict, not_pending: :conflict, adjustment_pending: :conflict, central_exists: :conflict,
                       unit_taken: :conflict, already_linked: :conflict,
                       same_user: :forbidden, missing_role: :forbidden,
                       controlled_requires_pharmacist: :forbidden, free_text_requires_pharmacist: :forbidden,
                       not_found: :not_found, prescription_not_found: :not_found,
                       catalog_unavailable: :service_unavailable }.freeze
    DEFAULT_LIMIT = Catalog::DEFAULT_LIMIT
    MAX_LIMIT = Catalog::MAX_LIMIT
    KEY_PATH_MAX = 64

    before_action :require_pharmacy!

    private

    # `{ error, path?, next_allowed_on?, problems? }`: só quando o resultado traz.
    def render_failure(result)
      payload = { error: result.reason.to_s }
      %i[path next_allowed_on problems].each { |key| payload[key] = result.details[key] if result.details[key] }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    # 422 no formato uniforme das escritas e listas de transferência e entrada:
    # `error`/`path` no topo e `problems` com pelo menos esse problema.
    def render_refusal(path, error = "invalid_request")
      render json: { error: error.to_s, path: path, problems: [ { path: path, error: error.to_s } ] }, status: :unprocessable_entity
    end

    def render_error(reason, status = :unprocessable_entity) = render(json: { error: reason.to_s }, status: status)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # Cursor [iso8601(6), id] das listas por (created_at DESC, id DESC): a data
    # legível e o id uuid.
    def valid_cursor?(cursor)
      return false unless cursor && cursor.size == 2 && uuid?(cursor.last)

      Time.iso8601(cursor.first)
      true
    rescue ArgumentError
      false
    end

    # `store:` de `rate_limit` é avaliado no carregamento da classe; o delegador
    # resolve Rails.cache a cada requisição (o padrão do Surveillance).
    module RateLimitStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    # Quem dispensa: `pharmacist` ou `pharmacy_assistant` (papel válido, com
    # vínculo) de um local `unit` ATIVO. Receita, busca de pessoa e duplicados.
    def dispenser_at?(location)
      location.kind == "unit" && location.active && Access.allowed?(user: Current.user, location: location, roles: Catalog::DISPENSER_ROLES)
    end

    # O mesmo, em algum local `unit` ativo (rotas sem `location_id`).
    def dispenser_anywhere?
      by_location = Access.roles_by_location(Current.user).select { |_id, roles| roles.intersect?(Set.new(Catalog::DISPENSER_ROLES)) }
      by_location.any? && StockLocation.active_locations.where(kind: "unit", id: by_location.keys).exists?
    end

    # Local do corpo (existente, ativo ou não); senão 422 `location_id` e nil.
    def body_location_or_refuse
      id = body_param("location_id")
      location = uuid?(id) ? StockLocation.find_by(id: id) : nil
      render_refusal("location_id") unless location
      location
    end

    def admin? = Current.user.has_role?("municipal_admin")

    # Local de estoque ativo pelo uuid de `key` (corpo ou query); senão nil.
    def location_param(key = "location_id")
      raw = params[key]
      return nil unless uuid?(raw)

      StockLocation.active_locations.find_by(id: raw)
    end

    # Dado do paciente e texto livre só do corpo JSON: na query vale como
    # ausente. O padrão do CareRegulation::BaseController.
    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Rotas cujo dado sensível só vem no corpo: query com chave fora de
    # `allowed` → 422 invalid_request com o path (a primeira chave
    # desconhecida, truncada; só o NOME da chave, nunca o valor).
    def query_only!(*allowed)
      unknown = (request.query_parameters.keys - allowed.map(&:to_s)).first
      return true unless unknown

      render_refusal(unknown.to_s[0, KEY_PATH_MAX])
      false
    end

    # Tamanho da página das listas: padrão 50, máximo 100; inválido → 422.
    # Devolve nil depois de responder.
    def page_limit
      raw = params[:limit]
      return DEFAULT_LIMIT if raw.blank?

      value = Integer(raw.to_s, 10, exception: false)
      return value if value && value.between?(1, MAX_LIMIT)

      render_refusal("limit", "invalid_limit")
      nil
    end
  end
end
