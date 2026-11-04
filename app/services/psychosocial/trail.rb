# Trilha da leitura nominal do CAPS (ADR 0049; plano, Desvio 13; contrato
# §14): o clinical_record.viewed do 19a com access "psychosocial" e o recurso
# lido. Só ids: nunca nome, CID, substância nem texto. Listas não gravam trilha.
module Psychosocial
  module Trail
    RESOURCES = %w[enrollment referral action care_plans timeline raas_sheet raas_file night_stay matrix_support
                   link_shared_cases documents person_lookup patient_duplicates].freeze

    module_function

    # patient: Patient ou o id.
    def viewed!(patient:, user:, resource:)
      raise ArgumentError, "recurso fora da trilha do CAPS: #{resource}" unless RESOURCES.include?(resource.to_s)

      patient_id = patient.respond_to?(:id) ? patient.id : patient
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: Catalog::TRAIL_ACCESS,
                                                     reason_code: nil, resource: resource.to_s)
    end

    # Busca de pessoa (`person_lookup`) e duplicados (`patient_duplicates`)
    # (contrato P30, na forma do 30/29): uma por pessoa mostrada, sem dado
    # clínico; também com `resource`, como todo clinical_record.viewed do CAPS.
    PERSON_RESOURCES = %w[person_lookup patient_duplicates].freeze

    def person_viewed!(user:, patient_id:, resource:)
      raise ArgumentError, "recurso fora da busca de pessoa: #{resource}" unless PERSON_RESOURCES.include?(resource.to_s)

      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: Catalog::TRAIL_ACCESS,
                                                     reason_code: nil, resource: resource.to_s, person_ref: "patient:#{patient_id}")
    end
  end
end
