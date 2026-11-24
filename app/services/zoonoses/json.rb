# Formas JSON do centro de zoonoses (módulo 35b, ADR 0054; contrato §2, §16,
# Q2, Q9). Sigilo:
#   - o microchip nunca sai, só `has_microchip`;
#   - a linha de lista e a resposta da escrita nunca trazem o tutor, só
#     `has_tutor` e `community`;
#   - o detalhe traz o tutor só como `{ id, display_name }` (o mesmo do 24a);
#   - o histórico (Q2, montado por consulta, sem tabela de eventos) só com
#     ids, datas, códigos e a veterinária `{ name, crmv }` quando houver (o
#     mesmo formato da resposta da escrita): nunca nota,
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

    # Campanha antirrábica (§3): sem dado pessoal.
    def campaign(campaign)
      { id: campaign.id, name: campaign.name, year: campaign.year, starts_on: campaign.starts_on.iso8601,
        ends_on: campaign.ends_on.iso8601, goal_dogs: campaign.goal_dogs, goal_cats: campaign.goal_cats, stage: campaign.stage,
        version: campaign.version, created_at: campaign.created_at.iso8601 }
    end

    # Dose antirrábica na lista e na resposta da escrita (§3, §16): só ids,
    # datas e códigos. Nunca o tutor, o nome do animal, a nota do evento
    # adverso nem o motivo da anulação.
    def rabies_vaccination(row)
      { id: row.id, modality: row.modality, campaign_id: row.campaign_id, animal_id: row.animal_id, species: row.species,
        vaccinated_on: row.vaccinated_on.iso8601, health_unit_id: row.health_unit_id, household_id: row.household_id,
        vector_product_id: row.vector_product_id, stock_lot_id: row.stock_lot_id, adverse_event: row.adverse_event,
        cancelled: row.cancelled?, cancelled_at: row.cancelled_at&.iso8601, recorded_by_user_id: row.recorded_by_user_id,
        created_at: row.created_at.iso8601 }
    end

    # Demanda da ouvidoria na fila do centro (§4, Q13): o subtipo, o estado,
    # o prazo e a cor do encaminhamento (Ombudsman::Deadlines), a versão e o
    # estado do encaminhamento. Nunca o extrato, o place_address, o
    # protocolo, a identidade, o contato nem os anexos da manifestação.
    def demand(row, forwarding, settings:, today:)
      { id: row.id, subtype: row.subtype, state: row.state, due_on: forwarding.due_on.iso8601,
        color: Ombudsman::Deadlines.forwarding_color(forwarding, settings, today: today), version: row.version,
        forwarding_state: forwarding.state }
    end

    # A resposta da escrita: a linha da fila com as datas e o desfecho, ainda
    # sem o extrato, o endereço e a nota.
    def demand_record(row, forwarding, settings:, today:)
      demand(row, forwarding, settings: settings, today: today)
        .merge(scheduled_on: row.scheduled_on&.iso8601, inspected_on: row.inspected_on&.iso8601, outcome: row.outcome)
    end

    # O detalhe (Q13, Q33): acrescenta o extrato (o texto do cidadão), o
    # place_address da manifestação e a nota da inspeção. Quem chama grava a
    # trilha zoonoses_demand.viewed.
    def demand_detail(row, forwarding, manifestation, settings:, today:)
      demand_record(row, forwarding, settings: settings, today: today)
        .merge(extract: forwarding.extract, place_address: manifestation.place_address, inspection_note: row.inspection_note,
               created_at: row.created_at.iso8601)
    end

    # Estada no canil (§7) na lista e na resposta da escrita: só ids, datas,
    # códigos e a espécie do animal (`animal` já carregado ou lido aqui).
    # Nunca o tutor nem o adotante (nem o id dele), nem o nome do animal.
    def shelter_stay(row, species: row.animal.species)
      { id: row.id, animal_id: row.animal_id, species: species, health_unit_id: row.health_unit_id, entry_kind: row.entry_kind,
        entered_on: row.entered_on.iso8601, bite_observation_id: row.bite_observation_id, exit_kind: row.exit_kind,
        exited_on: row.exited_on&.iso8601, version: row.version, created_at: row.created_at.iso8601 }
    end

    # Coleira (§6) na resposta da escrita. Sem tutor.
    def collar_record(row)
      collar(row).merge(animal_id: row.animal_id)
    end

    # Castração (§7) na resposta da escrita, com a veterinária (Q30).
    def neutering_record(row)
      { id: row.id, animal_id: row.animal_id, performed_on: row.performed_on.iso8601, shelter_stay_id: row.shelter_stay_id,
        veterinarian: veterinarian(row.professional), created_at: row.created_at.iso8601 }
    end

    # Eutanásia (§7) na resposta da escrita, com a veterinária (Q30). Nunca a
    # nota do motivo.
    def euthanasia_record(row)
      { id: row.id, animal_id: row.animal_id, performed_on: row.performed_on.iso8601, reason: row.reason, legal_basis: row.legal_basis,
        shelter_stay_id: row.shelter_stay_id, bite_observation_id: row.bite_observation_id,
        veterinarian: veterinarian(row.professional), created_at: row.created_at.iso8601 }
    end

    # Observação do animal agressor na fila do centro (§5, decisão 32): só o
    # bloco do animal — a espécie (congelada na abertura), a condição (da
    # ficha do 25: `condition`, já lida por quem chama), exposure_on, ends_on,
    # os dias que faltam (aberta: até ends_on, nunca negativo; fechada: nil),
    # estado, lugar, versão e animal_id. Nunca o paciente, a idade, a unidade,
    # a disease_notification_id nem o contato (este só em
    # Zoonoses::ObservationContact).
    def bite_observation(row, condition:, today:)
      { id: row.id, species: row.species, condition: condition, exposure_on: row.exposure_on.iso8601, ends_on: row.ends_on.iso8601,
        days_left: row.closed? ? nil : [ (row.ends_on - today).to_i, 0 ].max, state: row.state, place: row.place,
        version: row.version, animal_id: row.animal_id }
    end

    # O detalhe e a resposta da escrita: a linha da fila mais o desfecho.
    def bite_observation_detail(row, condition:, today:)
      bite_observation(row, condition: condition, today: today)
        .merge(outcome: row.outcome, outcome_on: row.outcome_on&.iso8601, outcome_note: row.outcome_note,
               closed_by_user_id: row.closed_by_user_id, created_at: row.created_at.iso8601)
    end

    # Inquérito de leishmaniose (§6) na lista: sem dado pessoal. below_focus_min
    # com os parâmetros da versão do inquérito (a tela avisa o foco pequeno).
    def leish_survey(row, parameters: Parameters.at(row.parameters_version))
      { id: row.id, name: row.name, kind: row.kind, neighborhood_id: row.neighborhood_id,
        neighborhood: { id: row.neighborhood_id, name: row.neighborhood.name }, city_block_ids: row.city_block_ids,
        dog_population: row.dog_population, target_dogs: row.target_dogs,
        below_focus_min: LeishSample.below_focus_min?(kind: row.kind, dog_population: row.dog_population, parameters: parameters),
        starts_on: row.starts_on.iso8601, ends_on: row.ends_on.iso8601, stage: row.stage, parameters_version: row.parameters_version,
        version: row.version, created_at: row.created_at.iso8601 }
    end

    # O detalhe e a resposta da escrita: mais os domicílios dos quarteirões
    # (Q21), a sugestão de população (Q18) e a prevalência.
    def leish_survey_detail(row)
      parameters = Parameters.at(row.parameters_version)
      leish_survey(row, parameters: parameters)
        .merge(household_ids: SurveyArea.household_ids(row.city_block_ids),
               dog_population_suggested: SurveyArea.suggested_population(row.city_block_ids, parameters: parameters),
               prevalence: Prevalence.for(row))
    end

    # Coleta e sorologia (§6) na lista e na resposta da escrita: o animal só
    # como `{ id, has_tutor }` (o desfecho pede tutor), nunca o tutor nem o
    # nome do animal (o molde da dose e da estada); o desfecho sem a nota.
    def leish_test_record(row)
      animal = row.animal
      outcome = row.outcome
      { id: row.id, version: row.version, leish_survey_id: row.leish_survey_id,
        animal: { id: animal.id, has_tutor: !animal.tutor_patient_id.nil? }, label: row.label,
        collected_on: row.collected_on.iso8601, dpp_result: row.dpp_result, dpp_on: row.dpp_on&.iso8601, elisa_result: row.elisa_result,
        elisa_on: row.elisa_on&.iso8601, elisa_request: row.elisa_request, result_by_user_id: row.result_by_user_id,
        outcome: outcome && { id: outcome.id, decision: outcome.decision, decided_on: outcome.decided_on.iso8601 },
        created_at: row.created_at.iso8601 }
    end

    # Desfecho do cão reagente (§6) na resposta da escrita: nunca a nota.
    def leish_outcome(row)
      { id: row.id, leish_test_id: row.leish_test_id, animal_id: row.animal_id, decision: row.decision,
        decided_on: row.decided_on.iso8601, euthanasia_id: row.euthanasia_id, created_at: row.created_at.iso8601 }
    end

    # `{ name, crmv }` do perfil profissional: o CRMV como "CRMV-<UF> <número>"
    # (o molde do ClinicalDocuments::Json; registro do conselho é público).
    def veterinarian(professional)
      { name: professional.professional_name,
        crmv: "#{professional.council}-#{professional.council_state} #{professional.registration_number}" }
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

    # Sem a disease_notification_id (decisão 32, §16): a notificação do 25 não sai do 35b.
    def observation(row)
      { id: row.id, exposure_on: row.exposure_on.iso8601, ends_on: row.ends_on.iso8601, place: row.place, state: row.state,
        outcome: row.outcome, outcome_on: row.outcome_on&.iso8601 }
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
        veterinarian: veterinarian(row.professional) }
    end

    def euthanasia(row)
      { id: row.id, performed_on: row.performed_on.iso8601, reason: row.reason, legal_basis: row.legal_basis,
        shelter_stay_id: row.shelter_stay_id, bite_observation_id: row.bite_observation_id,
        veterinarian: veterinarian(row.professional) }
    end

    private_class_method :veterinarian, :history, :vaccination, :observation, :leish_test, :collar, :stay, :neutering, :euthanasia
  end
end
