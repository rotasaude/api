# Tratamentos endodônticos do paciente e suas sessões (ADR 0046; contrato §16
# O14, O27): mais novos primeiro, com o nome de quem fez cada sessão.
module DentalCare
  class EndodonticsController < BaseController
    def index
      read_patient do |patient|
        limit = page_limit
        next false unless limit

        treatments = EndodonticTreatment.where(patient_id: patient.id)
                                        .includes(:health_unit, sessions: { consultation: { author_user: :professional } })
                                        .order(created_at: :desc, id: :desc).limit(limit).to_a
        render json: { treatments: treatments.map { |t| Json.endodontic_treatment(t) } }
        true
      end
    end
  end
end
