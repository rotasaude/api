# Pendências da competência (contrato §5 com B6; plano, Desvio 8): crítica
# recalculada na hora (sem gravar); entra o procedimento gravado, BPA, não
# faturável e de estabelecimento não-APS; `fix` pelo primeiro motivo
# corrigível. A trilha (tem paciente) é do controlador. `outcomes` é o mesmo
# recálculo que o resumo da competência aberta usa (§13 E17).
module Billing
  module Pending
    FIX = { "missing_professional_cns" => "professional", "missing_professional_cbo" => "professional", "missing_patient_id" => "patient",
            "missing_required_patient_field" => "patient", "missing_race_color" => "patient", "missing_address" => "patient",
            "missing_establishment_cnes" => "establishment" }.freeze

    module_function

    def call(period)
      labels = {}
      outcomes(period).filter_map do |procedure, outcome|
        next unless listed?(outcome)

        label = labels[[ procedure.sigtap_code, outcome.sigtap_competence ]] ||= Labels.procedure(procedure.sigtap_code, outcome.sigtap_competence)
        { procedure_id: procedure.id, reasons: outcome.reasons, fix: outcome.reasons.filter_map { |r| FIX[r] }.first || "procedure",
          performed_on: procedure.performed_on.iso8601, sigtap_code: procedure.sigtap_code, label: label,
          patient: { id: procedure.patient_id, display_name: procedure.patient.display_name },
          professional: { user_id: procedure.professional_user_id, name: Screenings::Json.staff_name(procedure.professional_user) } }
      end
    end

    # [procedimento, crítica recalculada] dos procedimentos gravados da competência, sem gravar.
    def outcomes(period)
      establishment = Establishment.of(BillingPeriod.find(period.id)) # cadastro de agora, nunca a associação em cache
      cache = SigtapCache.new
      PerformedProcedure.recorded.where(billing_period_id: period.id).includes(:patient, professional_user: :professional)
                        .order(:performed_on, :id).map { |procedure| [ procedure, Recalculate.outcome(procedure, establishment: establishment, cache: cache) ] }
    end

    def listed?(outcome) = !outcome.billable && outcome.instrument != "not_bpa" && !outcome.reasons.include?("establishment_is_aps")
  end
end
