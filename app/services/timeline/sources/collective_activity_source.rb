# Atividade coletiva na linha do tempo (módulo 24b, ADR 0052; contrato §12): uma
# entrada por participação do paciente da pessoa (collective_activity_participants;
# source_id = a participação), só do profissional (Query::PROFESSIONAL_ONLY_KINDS;
# a visão do cidadão é nula, fail-closed). A marcada por engano some.
#
# Título = rótulo do tipo (TipoAtividadeColetiva); resumo "Participou" e, com a
# avaliação do participante alterada, "· avaliação alterada" — nunca temas,
# públicos, práticas, procedimento, medidas, tabagismo nem o local. Unidade =
# a da atividade; profissional = o responsável, com o CBO gravado; status
# recorded; sem detail_ref (o contrato não abre o detalhe pela linha do tempo).
#
# A atividade só tem a data (held_on): occurred_at = meio-dia local do dia, na
# ordem, na janela e no cursor (noon_sql, como o trecho do TFD do módulo 30).
# NÃO consulta o interruptor (registro retido). A trilha é do controlador.
module Timeline
  module Sources
    module CollectiveActivitySource
      KIND = "collective_activity".freeze
      TYPE_LABELS = ::CollectiveActivities::Rules::DICTIONARY.dig("domains", "tipo_atividade_coletiva").freeze
      PARTICIPATED = "Participou".freeze
      ALTERED = "avaliação alterada".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        return [] unless person.patient_id

        scope = ::CollectiveActivityParticipant.joins(:collective_activity).where(patient_id: person.patient_id)
                                               .where(collective_activities: { mistaken_at: nil })
                                               .preload(collective_activity: %i[health_unit professional])
        Window.apply(scope, kind: KIND, column: noon_sql, id_column: "collective_activity_participants.id", before: before, from: from, to: to)
              .limit(limit).map { |participant| entry(participant) }
      end

      def entry(participant)
        activity = participant.collective_activity
        summary = participant.altered_evaluation == true ? "#{PARTICIPATED} · #{ALTERED}" : PARTICIPATED
        Entry.new(kind: KIND, source_id: participant.id, occurred_at: Time.zone.parse("#{activity.held_on.iso8601} 12:00"),
                  unit: Labels.unit(activity.health_unit), professional: { name: activity.professional.professional_name, cbo_code: activity.cbo },
                  title: TYPE_LABELS.fetch(activity.activity_type), summary: summary, status: "recorded", detail_ref: nil,
                  citizen: nil, document: nil)
      end
      private_class_method :entry

      # Meio-dia local do held_on, como timestamp UTC sem fuso (o tipo das colunas datetime).
      def noon_sql
        zone = ApplicationRecord.connection.quote(Time.zone.tzinfo.identifier)
        "(((collective_activities.held_on + TIME '12:00') AT TIME ZONE #{zone}) AT TIME ZONE 'UTC')"
      end
      private_class_method :noon_sql
    end
  end
end
