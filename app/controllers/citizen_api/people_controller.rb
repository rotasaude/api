# GET  /citizen/people — "para quem é esta triagem?": os CPFs ligados ao
#   telefone da sessão, mascarados, com o bairro declarado (ADR 0023) e o
#   perfil (ADR 0027; contratos §3.1).
# POST /citizen/people { cpf, consent_version, birth_date, sex, gender_identity?, neighborhood_id? }
#   — o par nasce COM o perfil (contratos §3.2). LGPD: nenhum CPF gravado sem o
#   termo vigente, nem com valor inválido. Par existente: 200 sem sobrescrever.
# POST /citizen/people/:id/profile { birth_date, sex, gender_identity } — corrige
#   o perfil declarado; o verificado só muda no posto (409 profile_verified).
# POST /citizen/people/:id/neighborhood { neighborhood_id | null } — troca o
#   bairro ("Trocar bairro" no wpda). Não muda triagem antiga: a cópia de cada
#   uma é imutável. Sem a chave: 422 (só null explícito apaga).
# GET  /citizen/people/:id/catalog — catálogo do par (contratos §3.4); sem perfil, 409.
module CitizenApi
  class PeopleController < BaseController
    def index
      people = current_citizen_session.citizens.includes(:neighborhood).order(:created_at)
      render json: { people: people.map { |c| person_json(c) } }
    end

    def create
      return render_error("consent_outdated", :conflict) unless params[:consent_version].to_s == Consents.current_version

      values = Citizens::ProfileValues.call(birth_date: params[:birth_date], sex: params[:sex],
                                            gender_identity: params[:gender_identity])
      return render_error(values.reason, :unprocessable_entity) if values.failure?

      neighborhood_id = requested_neighborhood_id
      return if performed?

      result = Citizens::RegisterPerson.call(phone: current_citizen_session.phone, cpf: params[:cpf], profile: values.payload)
      return render_error(result.reason, :unprocessable_entity) if result.failure?

      citizen = result.payload[:citizen]
      created = result.payload[:created]
      if created && neighborhood_id
        set = Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: neighborhood_id)
        return render_error(set.reason, :unprocessable_entity) if set.failure?
      end

      render json: { person: person_json(citizen.reload) }, status: created ? :created : :ok
    end

    def profile
      citizen = current_citizen_session.citizens.find_by(id: params[:id])
      return render_error("not_found", :not_found) unless citizen

      result = Citizens::SetProfile.call(citizen: citizen, birth_date: params[:birth_date], sex: params[:sex],
                                         gender_identity: params[:gender_identity])
      if result.failure?
        return render_error(result.reason, result.reason == :profile_verified ? :conflict : :unprocessable_entity)
      end

      render json: { person: person_json(citizen.reload) }
    end

    def catalog
      citizen = current_citizen_session.citizens.find_by(id: params[:id])
      return render_error("not_found", :not_found) unless citizen
      return render_error("profile_required", :conflict) unless citizen.profile?

      render json: Triages::Catalog.for(citizen: citizen)
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
        neighborhood: citizen.neighborhood && { id: citizen.neighborhood.id, name: citizen.neighborhood.name },
        profile: Citizens::ProfileJson.call(citizen)
      }
    end
  end
end
