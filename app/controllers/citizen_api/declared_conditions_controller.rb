#   GET    /citizen/declared_conditions?citizen_id=
#   POST   /citizen/declared_conditions   { citizen_id, condition } no CORPO
#   DELETE /citizen/declared_conditions?citizen_id=   { condition } no CORPO
# Condição declarada (ADR 0040; contrato §7 e §11 T1): só par validado do
# celular da sessão; care_lines ligado e utilizável. A condição (dado de
# saúde) nunca é lida da URL.
module CitizenApi
  class DeclaredConditionsController < BaseController
    include CareLinesGate

    before_action :require_care_lines!
    before_action :load_citizen

    def index = render(json: payload)

    def create
      result = CareLines::DeclareCondition.call(citizen: @citizen, condition: request.request_parameters["condition"])
      return render_error(result.reason, :unprocessable_entity) if result.failure?

      render json: payload, status: :created
    end

    # §11 T1: só o corpo JSON. Condição que veio na query string é ignorada
    # (e a falta no corpo é 422 invalid_condition).
    def destroy
      result = CareLines::WithdrawCondition.call(citizen: @citizen, condition: request.request_parameters["condition"])
      if result.failure?
        return render_error(result.reason, result.reason == :invalid_condition ? :unprocessable_entity : :not_found)
      end

      render json: payload
    end

    private

    def load_citizen
      @citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless @citizen

      render_error("not_verified", :forbidden) unless @citizen.verification_level_verified?
    end

    def payload
      rows = CitizenDeclaredCondition.current.where(citizen_id: @citizen.id).order(:declared_at).to_a
      { conditions: rows.map { |row| { condition: row.condition, declared_at: row.declared_at.iso8601 } } }
    end
  end
end
