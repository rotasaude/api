#   GET /citizen/trips?citizen_id=
# "Minhas viagens" (ADR 0048; contrato §8; §14 T14; Desvio 16): só o par
# validado do celular da sessão (senão 404 / 403 not_verified);
# `sanitary_transport` utilizável (senão 403 feature_disabled); com `tfd` não
# utilizável, "tfd": []. Os interruptores são lidos aqui, fora de qualquer
# transação da cidade. Forma fixa em Transport::CitizenView. Leitura com
# trilha citizen, uma vez por requisição, quando há paciente. Sem polling.
module CitizenApi
  class TripsController < BaseController
    before_action :require_sanitary_transport!

    def index
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless citizen
      return render_error("not_verified", :forbidden) unless citizen.verification_level_verified?

      tfd = Tfd::Gate.usable?(Current.city)
      person = Timeline::Person.for_citizen(citizen)
      Timeline::Trail.viewed!(person: person, access: "citizen") if person.patient_id
      render json: Transport::CitizenView.call(patient_id: person.patient_id, tfd: tfd)
    end

    private

    def require_sanitary_transport!
      return if Transport::Gate.usable?(Current.city)

      render json: { error: "feature_disabled", feature: Transport::Gate::KEY }, status: :forbidden
    end
  end
end
