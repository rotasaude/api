# Pendências da competência (contrato §5 com B6; plano, Desvio 8): crítica
# recalculada na hora (sem gravar); entra o procedimento gravado, BPA, não
# faturável e de estabelecimento não-APS; `fix` pelo primeiro motivo
# corrigível. A trilha (tem paciente) é do controlador.
module Billing
  module Pending
    FIX = { "missing_professional_cns" => "professional", "missing_professional_cbo" => "professional", "missing_patient_id" => "patient",
            "missing_required_patient_field" => "patient", "missing_race_color" => "patient", "missing_address" => "patient",
            "missing_establishment_cnes" => "establishment" }.freeze

    module_function

    def call(period)
      establishment = Establishment.of(BillingPeriod.find(period.id)) # cadastro de agora, nunca a associação em cache
      labels = {}
      PerformedProcedure.recorded.where(billing_period_id: period.id).includes(:patient, professional_user: :professional)
                        .order(:performed_on, :id).filter_map do |procedure|
        outcome = Recalculate.outcome(procedure, establishment: establishment)
        next if outcome.billable || outcome.instrument == "not_bpa" || outcome.reasons.include?("establishment_is_aps")

        label = labels[[ procedure.sigtap_code, outcome.sigtap_competence ]] ||= Labels.procedure(procedure.sigtap_code, outcome.sigtap_competence)
        { procedure_id: procedure.id, reasons: outcome.reasons, fix: outcome.reasons.filter_map { |r| FIX[r] }.first || "procedure",
          performed_on: procedure.performed_on.iso8601, sigtap_code: procedure.sigtap_code, label: label,
          patient: { id: procedure.patient_id, display_name: procedure.patient.display_name },
          professional: { user_id: procedure.professional_user_id, name: Screenings::Json.staff_name(procedure.professional_user) } }
      end
    end
  end
end
