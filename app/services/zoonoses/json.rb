# Formas JSON do centro de zoonoses (módulo 35b, ADR 0054; contrato §2, §16,
# Q2, Q9). Sigilo:
#   - o microchip nunca sai, só `has_microchip`;
#   - a linha de lista e a resposta da escrita nunca trazem o tutor, só
#     `has_tutor` e `community`;
#   - o detalhe traz o tutor só como `{ id, display_name }` (o mesmo do 24a);
#   - o histórico (Q2, montado por consulta, sem tabela de eventos) só com
#     ids, datas, códigos e o nome do veterinário quando houver: nunca nota,
#     motivo escrito, adotante, contato nem endereço.
module Zoonoses
  module Json
    module_function

    def animal(animal)
      { id: animal.id, species: animal.species, name: animal.name, sex: animal.sex, size: animal.size, coat: animal.coat,
        breed: animal.breed, birth_estimate_on: animal.birth_estimate_on&.iso8601, has_microchip: !animal.microchip.nil?,
        registry_number: animal.registry_number, household_id: animal.household_id, has_tutor: !animal.tutor_patient_id.nil?,
        community: animal.community, status: animal.status, status_on: animal.status_on&.iso8601, neutered: animal.neutered,
        version: animal.version, created_at: animal.created_at.iso8601 }
    end

    def animal_list(animals) = animals.map { |animal| animal(animal) }

    # `tutor`: o Patient do animal (ou nil); quem chama o carrega e grava a trilha.
    def animal_detail(animal, tutor:)
      animal(animal).merge(tutor: tutor && { id: tutor.id, display_name: tutor.display_name }, **history(animal.id))
    end

    # O histórico do animal (Q2), uma consulta por tabela, mais recente primeiro.
    def history(animal_id)
      { vaccinations: RabiesVaccination.where(animal_id: animal_id).order(vaccinated_on: :desc, created_at: :desc).map { vaccination(_1) },
        observations: BiteObservation.where(animal_id: animal_id).order(exposure_on: :desc, created_at: :desc).map { observation(_1) },
        tests: LeishTest.includes(:outcome).where(animal_id: animal_id).order(collected_on: :desc, created_at: :desc).map { leish_test(_1) },
        collars: Collar.where(animal_id: animal_id).order(placed_on: :desc, created_at: :desc).map { collar(_1) },
        stays: ShelterStay.where(animal_id: animal_id).order(entered_on: :desc, created_at: :desc).map { stay(_1) },
        neuterings: Neutering.includes(:professional).where(animal_id: animal_id).order(performed_on: :desc, created_at: :desc)
                             .map { neutering(_1) },
        euthanasia: Euthanasia.includes(:professional).where(animal_id: animal_id).order(created_at: :desc).first&.then { euthanasia(_1) } }
    end

    def vaccination(row)
      { id: row.id, vaccinated_on: row.vaccinated_on.iso8601, modality: row.modality, campaign_id: row.campaign_id,
        vector_product_id: row.vector_product_id, adverse_event: row.adverse_event, cancelled: row.cancelled? }
    end

    def observation(row)
      { id: row.id, disease_notification_id: row.disease_notification_id, exposure_on: row.exposure_on.iso8601,
        ends_on: row.ends_on.iso8601, place: row.place, state: row.state, outcome: row.outcome, outcome_on: row.outcome_on&.iso8601 }
    end

    def leish_test(row)
      outcome = row.outcome
      { id: row.id, leish_survey_id: row.leish_survey_id, collected_on: row.collected_on.iso8601, label: row.label,
        dpp_result: row.dpp_result, dpp_on: row.dpp_on&.iso8601, elisa_result: row.elisa_result, elisa_on: row.elisa_on&.iso8601,
        outcome: outcome && { id: outcome.id, decision: outcome.decision, decided_on: outcome.decided_on.iso8601 } }
    end

    def collar(row)
      { id: row.id, vector_product_id: row.vector_product_id, placed_on: row.placed_on.iso8601, due_on: row.due_on.iso8601,
        removed_on: row.removed_on&.iso8601, removal_reason: row.removal_reason }
    end

    def stay(row)
      { id: row.id, health_unit_id: row.health_unit_id, entry_kind: row.entry_kind, entered_on: row.entered_on.iso8601,
        exit_kind: row.exit_kind, exited_on: row.exited_on&.iso8601, bite_observation_id: row.bite_observation_id }
    end

    def neutering(row)
      { id: row.id, performed_on: row.performed_on.iso8601, shelter_stay_id: row.shelter_stay_id,
        veterinarian_name: row.professional.professional_name }
    end

    def euthanasia(row)
      { id: row.id, performed_on: row.performed_on.iso8601, reason: row.reason, legal_basis: row.legal_basis,
        shelter_stay_id: row.shelter_stay_id, bite_observation_id: row.bite_observation_id,
        veterinarian_name: row.professional.professional_name }
    end

    private_class_method :history, :vaccination, :observation, :leish_test, :collar, :stay, :neutering, :euthanasia
  end
end
