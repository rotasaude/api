# Trilha da leitura nominal do CAPS (ADR 0049; plano, Desvio 13; contrato
# §14): o clinical_record.viewed do 19a com access "psychosocial" e o recurso
# lido. Só ids: nunca nome, CID, substância nem texto. Listas não gravam trilha.
module Psychosocial
  module Trail
    RESOURCES = %w[enrollment referral action care_plans timeline raas_sheet raas_file night_stay matrix_support
                   link_shared_cases documents].freeze

    module_function

    # patient: Patient ou o id.
    def viewed!(patient:, user:, resource:)
      raise ArgumentError, "recurso fora da trilha do CAPS: #{resource}" unless RESOURCES.include?(resource.to_s)

      patient_id = patient.respond_to?(:id) ? patient.id : patient
      DomainEvents.publish("clinical_record.viewed", patient_id: patient_id, user_id: user.id, access: Catalog::TRAIL_ACCESS,
                                                     reason_code: nil, resource: resource.to_s)
    end
  end
end
