# Trilha da urgência (ADR 0050; plano, Desvio 15): o clinical_record.viewed do
# 19a com access "urgency", o recurso lido e o person_ref. Só ids: nunca nome,
# CPF, CNS, queixa nem a descrição do não identificado. Fila, painel, TV e
# listas não gravam trilha.
module Urgency
  module Trail
    # `patient_duplicates`: os candidatos do duplicado suspeito mostrados na
    # recepção (contrato §14 Q23), um por candidato, como no 31.
    RESOURCES = %w[person_lookup encounter patient_duplicates].freeze

    module_function

    def viewed!(user:, patient_id:, resource:)
      raise ArgumentError, "recurso fora da trilha da urgência: #{resource}" unless RESOURCES.include?(resource.to_s)

      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: Catalog::TRAIL_ACCESS,
                                                     reason_code: nil, resource: resource.to_s,
                                                     person_ref: "patient:#{patient_id}")
    end
  end
end
