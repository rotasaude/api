# GET /regulation/targets?type=&q=&limit= (contrato §13 G3; R2): busca de
# especialidade (CBO) ou procedimento SIGTAP regulável, para quem pede
# (health_professional) e para a regulação. Sem trilha: é catálogo.
module CareRegulation
  class TargetsController < BaseController
    ROLES = %w[health_professional care_regulator municipal_admin].freeze
    PROCEDURE_LIMIT = 20

    before_action { forbid unless ROLES.any? { |role| Current.user.has_role?(role) } }

    def index
      type = params[:type]
      return render_failure(Result.fail(:invalid_request, details: { path: "type" })) unless Catalog::TYPES.include?(type)

      query = params[:q]
      return render_failure(Result.fail(:invalid_request, details: { path: "q" })) unless query.nil? || query.is_a?(String)
      return render_error("invalid_query") if type == "procedure" && query.to_s.strip.length < Targets::MIN_QUERY

      limit = target_limit(type)
      return unless limit

      found = Targets.search(type: type, query: query, limit: limit)
      nurse_codes = NurseRequestableItem.where(target_type: type).pluck(:target_code).to_set
      render json: { targets: found.map { |target| entry(target, nurse_codes.include?(target.code)) } }
    end

    private

    # Especialidade: 1..MAX_LIMIT e, sem `limit`, a lista inteira (cabe em
    # MAX_LIMIT; o targets_yaml_spec garante). Procedimento: 1..20 e, sem
    # `limit`, 20. Fora disso → 422 invalid_limit (nada é cortado em silêncio).
    def target_limit(type)
      max = type == "procedure" ? PROCEDURE_LIMIT : MAX_LIMIT
      return max if params[:limit].blank?

      value = Integer(params[:limit].to_s, 10, exception: false)
      return value if value&.between?(1, max)

      render_error("invalid_limit")
      nil
    end

    def entry(target, nurse_allowed)
      { type: target.type, code: target.code, name: target.name, group: target.group, nurse_allowed: nurse_allowed }
    end
  end
end
