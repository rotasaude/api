#   GET /citizen/vaccinations?citizen_id=
# Caderneta de vacinação do cidadão (ADR 0047; contrato §9; §15 V11): só o par
# validado do celular da sessão (senão 404 / 403 not_verified); `vaccination`
# utilizável (senão 403 feature_disabled). Forma fixa em Vaccination::CitizenView.
# Leitura com trilha citizen, uma vez por requisição, quando há paciente. Sem polling.
module CitizenApi
  class VaccinationsController < BaseController
    before_action :require_vaccination!

    def index
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless citizen
      return render_error("not_verified", :forbidden) unless citizen.verification_level_verified?

      person = Timeline::Person.for_citizen(citizen)
      Timeline::Trail.viewed!(person: person, access: "citizen") if person.patient_id
      render json: Vaccination::CitizenView.call(patient_id: person.patient_id)
    end

    private

    def require_vaccination!
      return if Vaccination::Gate.usable?(Current.city)

      render json: { error: "feature_disabled", feature: Vaccination::Gate::KEY }, status: :forbidden
    end
  end
end
