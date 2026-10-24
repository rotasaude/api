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

    # address_from_household (módulo 24a, contrato §14 L6): o endereço do
    # paciente vem do cadastro domiciliar e a tela o mostra só leitura.
    def call(period)
      labels = {}
      rows = outcomes(period)
      from_household = IndividualRegistration.active_registrations.where.not(household_id: nil)
                                             .where(patient_id: rows.map { |procedure, _| procedure.patient_id }).distinct.pluck(:patient_id).to_set
      rows.filter_map do |procedure, outcome|
        next unless listed?(outcome)

        label = labels[[ procedure.sigtap_code, outcome.sigtap_competence ]] ||= Labels.procedure(procedure.sigtap_code, outcome.sigtap_competence)
        { procedure_id: procedure.id, reasons: outcome.reasons, fix: outcome.reasons.filter_map { |r| FIX[r] }.first || "procedure", late: procedure.late == true,
          performed_on: procedure.performed_on.iso8601, sigtap_code: procedure.sigtap_code, label: label,
          patient: { id: procedure.patient_id, display_name: procedure.patient.display_name,
                     **Patients::IdentifierJson.call(procedure.patient), address_from_household: from_household.include?(procedure.patient_id) },
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
