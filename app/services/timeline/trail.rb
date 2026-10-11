# Trilha de toda leitura da linha do tempo (ADR 0035, Invariantes): o mesmo
# clinical_record.viewed do 19a, com access timeline (profissional), citizen
# (wpda) ou pec_external (página do PEC) e a referência da pessoa. Só ids.
module Timeline
  module Trail
    ACCESS = %w[timeline citizen pec_external].freeze

    module_function

    def viewed!(person:, access:, user: nil, reason_code: nil)
      raise ArgumentError, "acesso fora da lista: #{access}" unless ACCESS.include?(access)

      DomainEvents.publish("clinical_record.viewed", patient_id: person.patient_id, user_id: user&.id, access: access,
                                                     reason_code: reason_code, person_ref: person.ref)
    end
  end
end
