# PATCH /billing/patients/:id/demographics (D-U1; contrato §13 E1): o
# faturista corrige raça/cor e endereço do paciente pendente. A resposta só
# diz se estão preenchidos (nunca os valores); trilha só com ids.
module Billing
  class PatientsController < BaseController
    def demographics
      return forbid unless Access.clerk?(Current.user)

      patient = uuid?(params[:id]) ? Patient.find_by(id: params[:id]) : nil
      return not_found unless patient

      attrs = params.to_unsafe_h.slice(*Patient::DEMOGRAPHICS)
      return render_error("invalid_demographics") if attrs.empty? # sem chave: nada a gravar, nada a auditar

      parsed = Patients::Demographics.parse(attrs)
      return render_failure(parsed) if parsed.failure?

      result = ApplicationRecord.transaction do
        patient.lock!
        saved = Patients::Demographics.save!(patient, parsed.payload[:values])
        DomainEvents.publish("billing_patient.demographics_updated", patient_id: patient.id, user_id: Current.user.id) if saved.ok?
        saved
      end
      return render_failure(result) if result.failure?

      render json: { patient: { id: patient.id, display_name: patient.display_name } }.merge(Patients::Demographics.flags(patient))
    end
  end
end
