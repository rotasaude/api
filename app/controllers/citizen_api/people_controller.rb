# GET /citizen/people — "para quem é esta triagem?": os CPFs ligados ao telefone
# da sessão, mascarados.
module CitizenApi
  class PeopleController < BaseController
    def index
      people = current_citizen_session.citizens.order(:created_at)
      render json: { people: people.map { |c| person_json(c) } }
    end

    private

    def person_json(citizen)
      { id: citizen.id, cpf_masked: citizen.cpf_masked, verification_level: citizen.verification_level }
    end
  end
end
