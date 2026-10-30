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
                              .includes(:problem_items, :conducts, :addenda, :dental_procedures, attendance: :health_unit, author_user: :professional)
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
        summary = if consultation.dental?
                    # Procedimentos só pelo nome SIGTAP: dente, face e quantidade são dado clínico fino.
                    [ problems.join("; ").presence, dental_procedures(consultation, labels), "adendos: #{consultation.addenda.size}" ].compact.join(" · ")
                  else
                    [ problems.join("; ").presence, "condutas: #{conducts}", "adendos: #{consultation.addenda.size}" ].compact.join(" · ")
                  end
        detail_ref = { type: "consultation", id: consultation.id }
        detail_ref[:kind] = "dental" if consultation.dental?
        title = consultation.dental? ? (consultation.baseline ? "Exame odontológico inicial" : "Consulta odontológica") : "Consulta"
        citizen_title = consultation.dental? ? "Consulta odontológica" : "Consulta"
        Entry.new(kind: KIND, source_id: consultation.id, occurred_at: consultation.finalized_at,
                  unit: { id: unit.id, name: unit.name },
                  professional: { name: Screenings::Json.staff_name(consultation.author_user), cbo_code: consultation.cbo_code },
                  title: title, summary: summary, status: consultation.status,
                  detail_ref: detail_ref,
                  citizen: { title: name ? "#{citizen_title} com #{name}" : citizen_title, summary: nil, status: nil, professional_name: name },
                  document: nil)
      end

      # Nomes SIGTAP distintos, na ordem de gravação (memo da chamada); nome
      # ausente sai pelo código, que não é dado de dente.
      def dental_procedures(consultation, labels)
        codes = consultation.dental_procedures.sort_by { |p| [ p.created_at, p.id ] }.map(&:procedure_code).uniq
        return nil if codes.empty?

        release = labels.fetch(:sigtap_release) { labels[:sigtap_release] = DentalCare::ProcedureSearch.release }
        names = codes.to_h do |code|
          [ code, labels.fetch([ :sigtap, code ]) { labels[[ :sigtap, code ]] = release && SigtapProcedure.find_by(release_id: release.id, code: code)&.name } ]
        end
        "procedimentos: #{codes.map { |code| names[code] || code }.join("; ")}"
      end
    end
  end
end
