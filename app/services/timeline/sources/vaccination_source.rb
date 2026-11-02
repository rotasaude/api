# Vacinas na linha do tempo (ADR 0047; contrato §10; §15 V10/V11, D11/W4): uma
# entrada por dose (immunizations.applied_at). Profissional: unidade da dose,
# vacinador com CBO, título "Vacina <nome> — <dose>", situação active ou
# cancelled e detail_ref { type: "immunization", id } (leitura nominal em
# GET /vaccination/immunizations/:id). Cidadão (`active_only`): só doses
# ativas, sem vacinador, resumo, situação nem documento; unidade nula na
# transcrição (o local é texto livre).
#
# NÃO consulta o interruptor `vaccination`: a dose é registro clínico retido e
# continua na linha do tempo com a sala desligada (como a dispensação). Vazia
# sem paciente. A trilha é do controlador (uma por leitura); nada de lote nem
# motivo sai daqui.
module Timeline
  module Sources
    module VaccinationSource
      KIND = "vaccination".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:, active_only: false)
        return [] unless person.patient_id

        scope = ::Immunization.where(patient_id: person.patient_id).includes(:health_unit, vaccinator_user: :professional)
        scope = scope.active if active_only
        rows = Window.apply(scope, kind: KIND, column: "immunizations.applied_at", id_column: "immunizations.id",
                                   before: before, from: from, to: to).limit(limit).to_a
        rows.map { |record| entry(record) }
      end

      def entry(record)
        name = ::Vaccination::Immunobiologicals.find(record.immunobiological_code)&.name
        title = "#{label(name)} — #{::Vaccination::Terminologies.name('dose', record.dose_code)}"
        place = record.health_unit
        Entry.new(kind: KIND, source_id: record.id, occurred_at: record.applied_at, unit: { id: place.id, name: place.name },
                  professional: { name: Labels.professional_name(record.vaccinator_user), cbo_code: record.vaccinator_cbo },
                  title: title, summary: nil, status: record.cancelled? ? "cancelled" : "active",
                  detail_ref: { type: "immunization", id: record.id },
                  citizen: { title: title, summary: nil, status: nil, professional_name: nil, unit: record.transcription ? nil : { id: place.id, name: place.name } },
                  document: nil)
      end
      private_class_method :entry

      # "Vacina <nome>": o catálogo já nomeia a maioria como "Vacina ...", sem repetir a palavra.
      def label(name) = name.to_s.start_with?("Vacina") ? name : "Vacina #{name}"
      private_class_method :label
    end
  end
end
