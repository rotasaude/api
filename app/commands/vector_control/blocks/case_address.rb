# Endereço do caso do bloqueio (módulo 35a, ADR 0054; contrato §8, §17; W-3):
# a única resposta do 35a com endereço de pessoa, para a coordenação escolher
# o quarteirão do caso sem lugar. Só a coordenação, com step-up (o
# controlador confere; aqui de novo o papel). Só em bloqueio proposed ou
# active (Q26(3): fechado ou descartado → invalid_transition path status, sem
# trilha; com ou sem lugar). Devolve o endereço do paciente e o do domicílio
# do cadastro individual ativo (24a, o endereço curto), se houver. Grava a
# trilha pelo mesmo mecanismo do 24a (clinical_record.viewed, access
# transmission_block_case, com patient_id), a do domicílio mostrado
# (TerritoryRegistry::Trail.household_viewed!, Q26(3)) e
# `transmission_block_case.address_viewed` (só ids do bloqueio e de quem
# leu). Nunca em lista, nunca por polling, nunca em log; o controlador
# responde com Cache-Control: no-store.
module VectorControl
  module Blocks
    module CaseAddress
      VIEWED = "transmission_block_case.address_viewed".freeze

      module_function

      # -> Result.ok(address: { patient_address:, household_address: }) | fail(:missing_role | :invalid_transition)
      def call(block:, block_case:, by:)
        return Result.fail(:missing_role) unless Access.coordinator?(by)
        return Support.transition unless Support::OPEN.include?(block.status)

        patient = block_case.disease_notification.patient
        household_id = CasePlace.household_id(patient.id)
        address = { patient_address: patient_address(patient),
                    household_address: household_id && HomeVisits::Json.addresses([ household_id ])[household_id] }
        DomainEvents.publish("clinical_record.viewed", patient_id: patient.id, user_id: by.id, access: Catalog::TRAIL_ACCESS,
                                                       reason_code: nil, person_ref: "patient:#{patient.id}",
                                                       transmission_block_id: block.id)
        TerritoryRegistry::Trail.household_viewed!(user: by, household_id: household_id) if household_id
        DomainEvents.publish(VIEWED, transmission_block_id: block.id, user_id: by.id)
        Result.ok(address: address)
      end

      def patient_address(patient)
        [ patient.address_street, patient.address_number, patient.address_complement, patient.address_district ]
          .compact_blank.join(", ").presence
      end
      private_class_method :patient_address
    end
  end
end
