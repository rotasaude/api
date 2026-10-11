# Escuta inicial (módulo 18): só a concluída. Profissional: cor, destino e
# CIAP-2 com nome. Cidadão: "Acolhimento realizado". Queixa, orientação e
# motivo da troca de cor (texto livre) nunca entram.
module Timeline
  module Sources
    module ScreeningSource
      KIND = "screening".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        scope = ::Screening.joins(:attendance).where(attendances: { citizen_id: person.citizen_ids }, status: "completed")
                           .includes(:current_revision, attendance: :health_unit, professional_link: :professional)
        Window.apply(scope, kind: KIND, column: "screenings.completed_at", id_column: "screenings.id",
                            before: before, from: from, to: to)
              .limit(limit).map { |screening| entry(screening) }
      end

      def entry(screening)
        revision = screening.current_revision
        unit = screening.attendance.health_unit
        name = screening.professional_link.professional.professional_name
        ciap = "#{revision.ciap2_code} #{Screenings::Ciap2.label(revision.ciap2_code, revision.ciap2_release_id)}".strip
        Entry.new(kind: KIND, source_id: screening.id, occurred_at: screening.completed_at,
                  unit: { id: unit.id, name: unit.name }, professional: { name: name, cbo_code: screening.cbo_code },
                  title: "Escuta inicial — #{Labels::COLORS.fetch(revision.final_color, revision.final_color)}",
                  summary: "#{Labels::DESTINATIONS.fetch(screening.destination, screening.destination)} · CIAP-2 #{ciap}",
                  status: screening.status, detail_ref: { type: "screening", id: screening.id },
                  citizen: { title: "Acolhimento realizado", summary: nil, status: nil, professional_name: name },
                  document: nil)
      end
    end
  end
end
