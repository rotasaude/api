# GET  /citizen/people — "para quem é esta triagem?": os CPFs ligados ao
#   telefone da sessão, mascarados, com o bairro declarado (ADR 0023).
# POST /citizen/people/:id/neighborhood { neighborhood_id | null } — troca o
#   bairro ("Trocar bairro" no wpda). Não muda triagem antiga: a cópia de cada
#   uma é imutável. Sem a chave: 422 (só null explícito apaga).
module CitizenApi
  class PeopleController < BaseController
    def index
      people = current_citizen_session.citizens.includes(:neighborhood).order(:created_at)
      render json: { people: people.map { |c| person_json(c) } }
    end

    def neighborhood
      citizen = current_citizen_session.citizens.find_by(id: params[:id])
      return render_error("not_found", :not_found) unless citizen

      raw = params[:neighborhood_id]
      unless params.key?(:neighborhood_id) && (raw.nil? || raw.is_a?(String))
        return render_error("invalid_neighborhood", :unprocessable_entity)
      end

      result = Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: raw)
      return render_error(result.reason, :unprocessable_entity) if result.failure?

      render json: { person: person_json(citizen.reload) }
    end

    private

    def person_json(citizen)
      {
        id: citizen.id, cpf_masked: citizen.cpf_masked, verification_level: citizen.verification_level,
        neighborhood: citizen.neighborhood && { id: citizen.neighborhood.id, name: citizen.neighborhood.name }
      }
    end
  end
end
