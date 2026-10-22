#   GET /citizen/care?citizen_id=
# "Meu acompanhamento" (ADR 0040; contrato §7): só par validado do celular
# da sessão (senão 404 / 403 not_verified); care_lines utilizável. Leitura
# com trilha citizen, uma vez por requisição, quando há paciente.
module CitizenApi
  class CareController < BaseController
    include CareLinesGate

    before_action :require_care_lines!

    def show
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      return render_error("not_found", :not_found) unless citizen
      return render_error("not_verified", :forbidden) unless citizen.verification_level_verified?

      person = Timeline::Person.for_citizen(citizen)
      Timeline::Trail.viewed!(person: person, access: "citizen") if person.patient_id
      render json: CareLines::CitizenView.call(citizen: citizen, person: person, today: Time.zone.today)
    end
  end
end
