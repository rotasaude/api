# Rede própria (ADR 0044; contrato §4, §13 G3; plano do api, Desvio 6, R13):
# autorizar numa oferta de prestador `own` abre, na MESMA transação do
# Authorize, o pedido de agendamento do módulo 17 (`kind: "regulated"`, origem
# no pedido de regulação) na unidade do prestador, para o par validado mais
# antigo do paciente. Sem par validado → NotVerified (o Authorize converte em
# citizen_not_verified e desfaz tudo).
#
# Ordem de travas (a do Authorize continua aqui): oferta (FOR UPDATE) →
# pedido de regulação → unidade (FOR SHARE; o Drain e a desativação a pegam
# FOR UPDATE primeiro) → pares (FOR NO KEY UPDATE, como
# CareLines::OpenAppointmentRequest: a revogação da validação e a exclusão LGPD
# esperam, e o par lido é o que vale) → criação.
#
# O chamador já deixou no pedido (em memória) a cor e o prazo resultantes:
# prioridade e prazo do pedido de agendamento são os do pedido de regulação.
module CareRegulation
  module OwnNetwork
    class NotVerified < StandardError; end

    DENTAL_TYPE = "consulta_odontologica".freeze
    MEDICAL_TYPE = "consulta_medica".freeze

    module_function

    # -> AppointmentRequest; levanta NotVerified ou HealthUnit::Inactive.
    def open!(request:, offer:, by:)
      unit = HealthUnit.lock_active!(offer.care_provider.health_unit_id)
      pairs = Citizen.not_erased.verification_level_verified.where(patient_id: request.patient_id)
                     .order(:id).lock("FOR NO KEY UPDATE").to_a
      raise NotVerified if pairs.empty?

      # O par mais antigo (pairs vem em order(:id) só para travar).
      oldest = pairs.min_by { |pair| [ pair.created_at, pair.id ] }
      created = AppointmentRequest.create!(kind: "regulated", origin_regulation_request: request, citizen: oldest,
                                           origin_unit_id: request.requester_unit_id, target_unit: unit,
                                           appointment_type_key: appointment_type_key(request),
                                           priority: request.effective_color == "red" ? "priority" : "routine",
                                           due_on: request.due_on)
      DomainEvents.publish("appointment_request.created", appointment_request_id: created.id, regulation_request_id: request.id,
                                                          target_unit_id: unit.id, kind: created.kind, user_id: by.id)
      created
    end

    # R13: especialidade odontológica (2232*) → consulta odontológica; o resto
    # (especialidade médica ou procedimento) → consulta médica.
    def appointment_type_key(request)
      dental = request.target_type == "specialty" && request.target_code.start_with?(Catalog::DENTIST_PREFIX)
      dental ? DENTAL_TYPE : MEDICAL_TYPE
    end
  end
end
