# Consultas (19a): só finalizadas, do paciente da pessoa. Profissional:
# problemas avaliados (código e nome da release gravada), quantas condutas e
# quantos adendos. Cidadão: "Consulta com <profissional>". SOAP nunca entra.
module Timeline
  module Sources
    module ConsultationSource
      KIND = "consultation".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        return [] unless person.patient_id

        scope = ::Consultation.finalized_consultations.where(patient_id: person.patient_id)
                              .includes(:problem_items, :conducts, :addenda, attendance: :health_unit, author_user: :professional)
        Window.apply(scope, kind: KIND, column: "consultations.finalized_at", id_column: "consultations.id",
                            before: before, from: from, to: to)
              .limit(limit).then do |page|
                labels = {} # memo da chamada: um rótulo por (terminologia, release, código)
                page.map { |consultation| entry(consultation, labels: labels) }
              end
      end

      def entry(consultation, labels: {})
        unit = consultation.attendance.health_unit
        name = Labels.professional_name(consultation.author_user)
        problems = consultation.problem_items.select { |p| p.addendum_id.nil? }.sort_by { |p| [ p.created_at, p.id ] }.map do |p|
          key = [ p.terminology, p.terminology_release_id, p.code ]
          label = labels.fetch(key) { labels[key] = ClinicalTerms.label(p.terminology, p.code, p.terminology_release_id) }
          "#{p.code} #{label}".strip
        end
        conducts = consultation.conducts.count { |c| c.addendum_id.nil? }
        summary = [ problems.join("; ").presence, "condutas: #{conducts}", "adendos: #{consultation.addenda.size}" ].compact.join(" · ")
        Entry.new(kind: KIND, source_id: consultation.id, occurred_at: consultation.finalized_at,
                  unit: { id: unit.id, name: unit.name },
                  professional: { name: Screenings::Json.staff_name(consultation.author_user), cbo_code: consultation.cbo_code },
                  title: "Consulta", summary: summary, status: consultation.status,
                  detail_ref: { type: "consultation", id: consultation.id },
                  citizen: { title: name ? "Consulta com #{name}" : "Consulta", summary: nil, status: nil, professional_name: name },
                  document: nil)
      end
    end
  end
end
