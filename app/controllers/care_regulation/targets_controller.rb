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
      return render_error("invalid_request") unless query.nil? || query.is_a?(String)
      return render_error("invalid_query") if type == "procedure" && query.to_s.strip.length < Targets::MIN_QUERY

      # Sem `limit`, a especialidade vem inteira (a lista cabe em MAX_LIMIT).
      limit = params[:limit].blank? ? MAX_LIMIT : page_limit
      return unless limit

      limit = [ limit, PROCEDURE_LIMIT ].min if type == "procedure"
      found = Targets.search(type: type, query: query, limit: limit)
      nurse_codes = NurseRequestableItem.where(target_type: type).pluck(:target_code).to_set
      render json: { targets: found.map { |target| entry(target, nurse_codes.include?(target.code)) } }
    end

    private

    def entry(target, nurse_allowed)
      { type: target.type, code: target.code, name: target.name, group: target.group, nurse_allowed: nurse_allowed }
    end
  end
end
