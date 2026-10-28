# Rede de segurança (módulo 25, ADR 0043; contrato §4): "possível notificação
# não feita". Na finalização, os itens `add` da própria consulta (sem os dos
# adendos); no adendo, só os itens `add` daquele adendo. `evaluate`, `resolve`
# e `correct_onset` nunca disparam. Uma `possible` por doença da lista casada
# (Matcher), sem notificador, quando nada a bloqueia (Duplicates.blocking, sob
# as travas do CreateNotification); already_notified é silêncio.
# suspected_at = finalized_at da consulta ou created_at do adendo; unidade = a
# do atendimento.
# Ordem de travas (Desvio 13; a mesma do NotifyFromConsultation e do
# AddAddendum): consulta (FOR UPDATE, aqui) → paciente → lock consultivo
# paciente×doença → notificação. Sem a consulta primeiro: o POST segura a
# consulta e espera o paciente; a rede segura o paciente e a FK do INSERT
# espera o KEY SHARE da consulta — deadlock. As doenças vão em ordem de código:
# uma rodada pode segurar vários locks consultivos até o commit.
# Doença e paciente nunca em log, evento, erro ou retorno (só a contagem).
module Surveillance
  module SafetyNet
    module_function

    # -> { created: Integer }
    def call(consultation:, addendum: nil, today: Time.zone.today)
      raise ArgumentError, "addendum of another consultation" if addendum && addendum.consultation_id != consultation.id

      created = 0
      ApplicationRecord.transaction do
        consultation.lock!
        next unless consultation.finalized?

        suspected_at = addendum ? addendum.created_at : consultation.finalized_at
        unit = consultation.attendance.health_unit
        diseases(consultation, addendum, today).each do |disease|
          result = CreateNotification.call(patient: consultation.patient, disease: disease, origin: "safety_net", unit: unit,
                                           suspected_at: suspected_at, consultation: consultation, addendum: addendum)
          if result.ok?
            created += 1
          elsif result.reason != :already_notified
            raise "safety net refused: #{result.reason}" # só o código do motivo
          end
        end
      end
      { created: created }
    end

    # Doenças da lista casadas pelos itens `add`, uma por código, em ordem de código.
    def diseases(consultation, addendum, today)
      list = Diseases.all(today: today)
      consultation.problem_items.where(action: "add", addendum_id: addendum&.id).pluck(:terminology, :code)
                  .filter_map { |terminology, code| Matcher.disease_for(terminology, code, list) }
                  .uniq(&:code).sort_by(&:code)
    end
    private_class_method :diseases
  end
end
