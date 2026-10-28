# "Notificar suspeita" na consulta (módulo 25, ADR 0043; contrato §4; K12(b)):
# a autora grava a notificação de qualquer doença da lista (a sugerida ou a
# escolhida à mão). O vínculo da consulta (consultation.cbo_code, o mesmo que o
# 19a usa para emitir) precisa começar por NOTIFIER_CBO_PREFIXES. Vale para
# consulta finalizada também (a tela deixa de oferecer; a rede de segurança
# disputa a mesma notificação e o índice único decide). Nunca toca a consulta.
# Doença, data de sintomas e paciente nunca em log nem em Result.
module Surveillance
  module NotifyFromConsultation
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    module_function

    # -> Result.ok(notification:) | fail(:missing_role | :not_found | :not_author |
    # :cbo_not_allowed | :invalid_disease | :invalid_symptoms_on) | os de CreateNotification.
    def call(consultation:, disease_code:, symptoms_on:, by:)
      return Result.fail(:missing_role) unless by&.has_role?("health_professional")

      ApplicationRecord.transaction do
        # Ordem de travas do CreateNotification: consulta → paciente.
        consultation.lock!
        next Result.fail(:not_found) if consultation.discarded?
        next Result.fail(:not_author) unless consultation.author_user_id == by.id
        next Result.fail(:cbo_not_allowed) unless consultation.cbo_code.to_s.start_with?(*Catalog::NOTIFIER_CBO_PREFIXES)

        disease = disease_code.is_a?(String) ? Diseases.find(disease_code) : nil
        next Result.fail(:invalid_disease) unless disease

        date = parse_date(symptoms_on)
        next Result.fail(:invalid_symptoms_on) if date == :invalid

        CreateNotification.call(patient: consultation.patient, disease: disease, origin: "consultation",
                                unit: consultation.attendance.health_unit, by: by, suspected_at: Time.current,
                                symptoms_on: date, consultation: consultation)
      end
    end

    # nil | Date | :invalid (só AAAA-MM-DD de um dia que existe).
    def parse_date(value)
      return nil if value.nil?
      return :invalid unless value.is_a?(String) && value.match?(DATE)

      Date.iso8601(value)
    rescue Date::Error
      :invalid
    end
    private_class_method :parse_date
  end
end
