# Formas JSON da atividade coletiva (módulo 24b, ADR 0052; contrato §7, §13;
# Q13–Q15, Q17). Profissional por id, nome e CBO; paciente com has_cpf e o CNS
# mascarado, nunca CPF nem CNS inteiros.
module CollectiveActivities
  module Json
    # Os campos que a lista não traz (§7: "sem participants nem temas"): os
    # participantes, as quatro listas cifradas e o procedimento.
    DETAIL_ONLY = %i[meeting_topics target_audience health_topics health_practices procedure_code participants].freeze

    module_function

    # <collective_activity> do §7, para uma lista, com um número fixo de
    # consultas. `full: false` = a forma da lista (sem DETAIL_ONLY); só a
    # completa é nominal (quem mostra grava a trilha). mistaken.reason só
    # para quem registrou e o enfermeiro/médico da equipe, nulo para os
    # outros (Q17); can_mark_mistaken = quem registrou e não marcada (Q14).
    def activities(activities, viewer:, full: true)
      return [] if activities.empty?

      associations = [ :place_health_unit, { team: :health_unit }, { recorded_by_user: :professional },
                       { mistaken_by_user: :professional }, { professionals: :professional } ]
      associations << { participants: :patient } if full
      ActiveRecord::Associations::Preloader.new(records: activities, associations: associations).call
      fichas = fichas(activities)
      supervised = activities.map(&:team).uniq(&:id).to_h { |team| [ team.id, Access.supervises?(viewer, team) ] }
      activities.map do |activity|
        marker = Access.marker?(viewer, activity)
        json = activity_json(activity, ficha: fichas.fetch(activity.id), reason_visible: marker || supervised[activity.team_id],
                                       can_mark: marker && !activity.mistaken?)
        full ? json : json.except(*DETAIL_ONLY)
      end
    end

    def activity_json(activity, ficha:, reason_visible:, can_mark:)
      place = activity.place_health_unit
      {
        id: activity.id, client_uuid: activity.client_uuid, team: { id: activity.team.id, ine: activity.team.ine, name: activity.team.name },
        unit: { id: activity.team.health_unit.id, name: activity.team.health_unit.name }, held_on: activity.held_on.iso8601,
        shift: activity.shift, activity_type: activity.activity_type,
        place: place ? { health_unit: { id: place.id, name: place.name } } : { text: activity.place_text },
        participants_count: activity.participants_count, altered_count: activity.altered_count,
        meeting_topics: Array(activity.meeting_topics), target_audience: Array(activity.target_audience),
        health_topics: Array(activity.health_topics), health_practices: Array(activity.health_practices),
        procedure_code: activity.procedure_code,
        professionals: activity.professionals.sort_by { |row| [ row.created_at, row.id ] }.map do |row|
          { id: row.professional.id, name: row.professional.professional_name, cbo: row.cbo }
        end,
        participants: participants(activity),
        recorded_by: { name: activity.recorded_by_user.professional&.professional_name }, state: activity.state,
        mistaken: mistaken(activity, reason_visible), ficha: ficha, can_mark_mistaken: can_mark
      }
    end

    # Só com os participantes carregados (a forma completa); na ordem da ficha.
    def participants(activity)
      return [] unless activity.association(:participants).loaded?

      activity.participants.sort_by { |row| [ row.created_at, row.id ] }.map do |row|
        patient = row.patient
        { patient: { id: patient.id, display_name: patient.display_name }.merge(Patients::IdentifierJson.call(patient)),
          altered_evaluation: row.altered_evaluation == true, measurements: row.measurements.presence, smoking: row.smoking.presence }
      end
    end

    def mistaken(activity, reason_visible)
      return nil unless activity.mistaken?

      { at: activity.mistaken_at.iso8601, reason: (activity.mistaken_reason if reason_visible),
        by: { name: activity.mistaken_by_user.professional&.professional_name } }
    end

    # Situação da ficha 6 (§7, §11; Desvio 3, Q5): o motivo da "não gerada"
    # ainda não resolvida (not_generated, com os códigos) | o status do
    # ledi_outbox mais recente da fonte (a regerada pelo "Reenviar" substitui a
    # recusada) | not_exported (sem ficha e sem falha: a exportação não estava
    # utilizável). -> { activity_id => { status:, reasons: } }
    def fichas(activities)
      source = { source_type: Ledi::CollectiveActivityFicha::SOURCE_TYPE, source_id: activities.map(&:id) }
      failures = LediGenerationFailure.unresolved.where(source).index_by(&:source_id)
      statuses = LediOutboxEntry.where(source).order(created_at: :desc, id: :desc).pluck(:source_id, :status)
                                .each_with_object({}) { |(id, status), latest| latest[id] ||= status }
      activities.to_h do |activity|
        ficha = if (failure = failures[activity.id]) then { status: "not_generated", reasons: failure.reason_codes }
                elsif (status = statuses[activity.id]) then { status: status, reasons: [] }
                else { status: "not_exported", reasons: [] }
                end
        [ activity.id, ficha ]
      end
    end

    # `options.domains` (§7, Q13): a forma `collective_activity`, lida do YAML
    # da task 1 (o mesmo que preenche o domains-v1.json do app e dirige o
    # CollectiveActivities::Rules), com as regras do §4 em dado.
    def domains = DOMAINS

    def build_domains
      domains = Rules::DICTIONARY.fetch("domains")
      rules = Rules::RULES
      {
        activity_types: labels(domains.fetch("tipo_atividade_coletiva")),
        meeting_topics: labels(domains.fetch("temas_para_reuniao")),
        target_audience: labels(domains.fetch("publico_alvo")),
        health_topics: labels(domains.fetch("temas_para_saude")),
        health_practices: labels(domains.fetch("praticas_em_saude")),
        procedures: domains.fetch("outro_procedimento_coletivo").map { |code, label| { code: code.to_s, label: label } },
        rules: {
          list_max: rules.fetch("list_max").transform_keys(&:to_sym),
          by_type: Rules::BY_TYPE.to_h { |type, row| [ type.to_s, row.transform_keys(&:to_sym) ] },
          health_topics_with_meeting_topic: [ Rules::MEETING_EXCEPTION ],
          practices_only_in_type: [ { type: 6, practices: Rules::TYPE6_ONLY } ],
          procedure_practices: [ Rules::PROCEDURE_PRACTICE ],
          smoking_practices: Rules::SMOKING_PRACTICES,
          participant_measurements: Rules::PARTICIPANT_MEASUREMENTS.to_h do |key, row|
            [ key.to_sym, { min: row.fetch("min"), max: row.fetch("max"), decimals: row.fetch("decimals") } ]
          end
        }
      }.freeze
    end

    def labels(rows) = rows.map { |code, label| { code: code, label: label } }

    DOMAINS = build_domains
    private_class_method :build_domains, :labels, :activity_json, :participants, :mistaken, :fichas
  end
end
