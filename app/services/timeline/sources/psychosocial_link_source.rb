# Marcador do vínculo com o CAPS na linha do tempo do PROFISSIONAL (ADR 0049;
# contrato §10, P18, P46): kind `psychosocial_link`, fora de Timeline::KINDS
# (só Query::PROFESSIONAL_KINDS) — nunca no cidadão nem no PEC externo. Uma
# entrada por matrícula do paciente, no início (dia local de `started_on`):
# "Acompanhamento no CAPS", "Desde dd/mm/aaaa" ou "dd/mm/aaaa a dd/mm/aaaa".
# Sem nome nem modalidade da unidade (decisão do usuário, P46), sem
# profissional, CID, substância nem texto; `detail_ref` nulo (o vínculo visto
# pela UBS é GET /psychosocial/patients/:id/link, com as regras dele).
module Timeline
  module Sources
    module PsychosocialLinkSource
      KIND = "psychosocial_link".freeze
      TITLE = "Acompanhamento no CAPS".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        return [] unless person.patient_id

        # O início é uma data; a janela e o cursor comparam o instante UTC da
        # meia-noite local (o mesmo occurred_at da entrada).
        zone = ::ApplicationRecord.connection.quote(Time.zone.tzinfo.name)
        column = "((psychosocial_enrollments.started_on::timestamp AT TIME ZONE #{zone}) AT TIME ZONE 'UTC')"
        scope = ::PsychosocialEnrollment.where(patient_id: person.patient_id)
        Window.apply(scope, kind: KIND, column: column, id_column: "psychosocial_enrollments.id", before: before, from: from, to: to)
              .limit(limit).to_a.map { |enrollment| entry(enrollment) }
      end

      def entry(enrollment)
        Entry.new(kind: KIND, source_id: enrollment.id, occurred_at: enrollment.started_on.in_time_zone, unit: nil, professional: nil,
                  title: TITLE, summary: summary(enrollment), status: enrollment.open? ? "open" : "closed", detail_ref: nil,
                  citizen: nil, document: nil)
      end
      private_class_method :entry

      def summary(enrollment)
        start = enrollment.started_on.strftime("%d/%m/%Y")
        enrollment.open? ? "Desde #{start}" : "#{start} a #{enrollment.closed_on.strftime('%d/%m/%Y')}"
      end
      private_class_method :summary
    end
  end
end
