# Procedimentos realizados (ADR 0039; contrato §9; fecha api#71 para
# procedimentos): um por procedimento gravado (performed_procedures.created_at),
# cancelado fora. Profissional: nome SIGTAP, unidade (ou o laboratório) e
# profissional com CBO; nunca crítica nem faturamento. Cidadão: nome, unidade
# e situação "Realizado". Vazio sem procedure_billing ou sem paciente. A
# trilha é do controlador (uma por leitura).
module Timeline
  module Sources
    module ProcedureSource
      KIND = "procedure".freeze
      CITIZEN_STATUS = "Realizado".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        return [] unless person.patient_id && Billing::Gate.enabled?(Current.city)

        scope = ::PerformedProcedure.recorded.where(patient_id: person.patient_id)
                                    .includes(:health_unit, :exam_provider, professional_user: :professional)
        rows = Window.apply(scope, kind: KIND, column: "performed_procedures.created_at", id_column: "performed_procedures.id",
                                   before: before, from: from, to: to).limit(limit).to_a
        labels = {}
        rows.map { |procedure| entry(procedure, labels) }
      end

      def entry(procedure, labels)
        title = labels[[ procedure.sigtap_code, procedure.sigtap_competence ]] ||=
          Billing::Labels.procedure(procedure.sigtap_code, procedure.sigtap_competence)
        place = Billing::Establishment.of(procedure)
        Entry.new(kind: KIND, source_id: procedure.id, occurred_at: procedure.created_at, unit: { id: place.id, name: place.name },
                  professional: { name: Labels.professional_name(procedure.professional_user), cbo_code: procedure.cbo_code },
                  title: title, summary: "Realizado em #{procedure.performed_on.strftime('%d/%m/%Y')}", status: "recorded",
                  detail_ref: { type: "performed_procedure", id: procedure.id },
                  citizen: { title: title, summary: "Realizado em #{procedure.performed_on.strftime('%d/%m/%Y')}", status: "recorded", status_label: CITIZEN_STATUS, professional_name: nil },
                  document: nil)
      end
      private_class_method :entry
    end
  end
end
