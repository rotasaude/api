# Triagens (módulos 01/03/15): da conversa de um par da pessoa, sem as em
# andamento. Profissional: protocolo, prioridade, classificação. Cidadão:
# protocolo, data, prioridade.
module Timeline
  module Sources
    module TriageSource
      KIND = "triage".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        scope = ::Triage.joins(:conversation).where(conversations: { citizen_id: person.citizen_ids })
                        .where.not(status: "in_progress").includes(:protocol_definition)
        Window.apply(scope, kind: KIND, column: "triages.created_at", id_column: "triages.id", before: before, from: from, to: to)
              .limit(limit).map { |triage| entry(triage) }
      end

      def entry(triage)
        definition = triage.protocol_definition&.definition
        protocol = (definition.is_a?(Hash) && definition.dig("offer", "title").presence) || triage.protocol_name
        priority = triage.priority && "Prioridade #{triage.priority}"
        summary = [ priority, triage.tier && "Classificação #{triage.tier}" ].compact.join(" · ").presence
        Entry.new(kind: KIND, source_id: triage.id, occurred_at: triage.created_at, unit: nil, professional: nil,
                  title: "Triagem — #{protocol}", summary: summary, status: triage.status,
                  detail_ref: { type: "triage", id: triage.id },
                  citizen: { title: "Triagem — #{protocol}", summary: priority, status: triage.status, professional_name: nil },
                  document: nil)
      end
    end
  end
end
