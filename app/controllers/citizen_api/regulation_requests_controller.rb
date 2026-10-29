#   GET /citizen/regulation_requests?citizen_id=
# "Meus encaminhamentos" (ADR 0044; contrato §9, §13 G3/G9): só o par validado
# do celular da sessão (senão 404 / 403 not_verified); care_regulation
# utilizável (senão 403 feature_disabled). Forma fixa e sem cor, posição, CID
# nem justificativa (CareRegulation::CitizenView). Leitura com trilha citizen,
# uma vez por requisição, quando há paciente.
module CitizenApi
  class RegulationRequestsController < BaseController
    before_action :require_care_regulation!

    def index
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless citizen
      return render_error("not_verified", :forbidden) unless citizen.verification_level_verified?

      person = Timeline::Person.for_citizen(citizen)
      Timeline::Trail.viewed!(person: person, access: "citizen") if person.patient_id
      render json: { requests: CareRegulation::CitizenView.call(patient_id: person.patient_id) }
    end

    private

    def require_care_regulation!
      return if CareRegulation::Gate.usable?(Current.city)

      render json: { error: "feature_disabled", feature: CareRegulation::Gate::KEY }, status: :forbidden
    end
  end
end
