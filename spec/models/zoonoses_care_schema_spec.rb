require "rails_helper"
require Rails.root.join("db/city_migrate/20261123900003_add_zoonoses_care.rb").to_s

# Módulo 35b (ADR 0054; contrato §1, §4–§7, Q16, Q18, Q21; plano, Task 4): o
# banco da demanda, da observação do agressor, da leishmaniose, do canil, da
# castração e da eutanásia, e as listas do field-sync. Cada regra do banco é
# provada pela mensagem do trigger ou pelo nome da constraint, nunca por um
# StatementInvalid qualquer.
RSpec.describe "Esquema do cuidado do módulo 35b", type: :model do
  before { zoonoses_city! }

  # Escrita crua que o banco recusa: sem savepoint a recusa aborta a transação do exemplo.
  def refused(pattern, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def accepted(&block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.not_to raise_error
  end

  def raw_update(record, **attrs) = record.class.where(id: record.id).update_all(attrs)

  # Avaliados antes de qualquer savepoint recusado (que desfaria as linhas).
  let!(:vet) { veterinarian! }
  let!(:unit) { uvz_unit! }

  # Encaminhamento da ouvidoria direto na linha (o do sistema, Q13); o comando
  # da demanda nasce na Task 6.
  def forwarding!
    OmbudsmanForwarding.create!(ombudsman_manifestation: raw_manifestation!(channel: "in_person"), department: department!,
                                extract: "Extrato do caso para o setor responder.", due_on: Date.current + 20, state: "pending",
                                created_by_system: true)
  end

  def demand!(forwarding: forwarding!, **over)
    ZoonosesDemand.create!({ ombudsman_forwarding: forwarding, subtype: "scorpion" }.merge(over))
  end

  def stay!(animal: animal!, **over) = shelter_stay!(animal: animal, **over)

  def outcome_attrs(test, **over)
    { animal: test.animal, leish_test: test, decision: "refused", decided_on: Time.zone.today }.merge(over)
  end

  def leish_test!(animal: animal!, survey: nil, **over)
    LeishTest.create!({ animal: animal, leish_survey: survey, collected_on: Time.zone.today,
                        label: "LV-2026-AVUL-#{SecureRandom.hex(3).upcase}" }.merge(over))
  end

  it "a migração espelha Zoonoses::Catalog e FieldSync::Catalog (menos o que a Task 17 traz); irreversível" do
    c = Zoonoses::Catalog
    expect([ AddZoonosesCare::SUBTYPES, AddZoonosesCare::DEMAND_STATES, AddZoonosesCare::DEMAND_OUTCOMES, AddZoonosesCare::PLACES,
             AddZoonosesCare::OBSERVATION_STATES, AddZoonosesCare::OBSERVATION_OUTCOMES, AddZoonosesCare::SURVEY_KINDS,
             AddZoonosesCare::SURVEY_STAGES, AddZoonosesCare::DPP_RESULTS, AddZoonosesCare::ELISA_RESULTS,
             AddZoonosesCare::LEISH_DECISIONS, AddZoonosesCare::ENTRY_KINDS, AddZoonosesCare::EXIT_KINDS,
             AddZoonosesCare::EUTHANASIA_REASONS, AddZoonosesCare::LEGAL_BASES ])
      .to eq([ c::SUBTYPES, c::DEMAND_STATES, c::DEMAND_OUTCOMES, c::PLACES, c::OBSERVATION_STATES, c::OBSERVATION_OUTCOMES,
               c::SURVEY_KINDS, c::SURVEY_STAGES, c::DPP_RESULTS, c::ELISA_RESULTS, c::LEISH_DECISIONS, c::ENTRY_KINDS, c::EXIT_KINDS,
               c::EUTHANASIA_REASONS, c::LEGAL_BASES ])
    expect(AddZoonosesCare::ITEM_TYPES).to include(*FieldSync::Catalog::ITEM_TYPES)
    expect(AddZoonosesCare::TOMBSTONE_ENTITY_TYPES).to include(*FieldSync::Catalog::TOMBSTONE_ENTITY_TYPES)
    expect(AddZoonosesCare::TOMBSTONE_REASONS).to include(*FieldSync::Catalog::TOMBSTONE_REASONS)
    expect { AddZoonosesCare.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  describe "observação do agressor" do
    it "segunda observação da notificação → único" do
      first = bite_observation!
      expect { bite_observation!(notification: first.disease_notification) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_bite_observations_notification/)
    end

    it "espécie só cão ou gato; fim depois da exposição; lugar e estado no domínio (sem cancelled, Q16)" do
      refused(/ck_bite_observations_species/) { bite_observation!(species: "bat") }
      refused(/ck_bite_observations_period/) { bite_observation!(ends_on: Time.zone.today - 3) }
      refused(/ck_bite_observations_place/) { bite_observation!(place: "street") }
      refused(/ck_bite_observations_state/) { bite_observation!(state: "cancelled") }
      refused(/ck_bite_observations_version/) { bite_observation!(version: 0) }
    end

    it "closed ⇔ desfecho ⇔ dia do desfecho; o dia não antes da exposição" do
      refused(/ck_bite_observations_outcome\b/) { bite_observation!(state: "closed", outcome: nil, outcome_on: nil) }
      refused(/ck_bite_observations_outcome\b/) { bite_observation!(state: "open", outcome: "healthy", outcome_on: Time.zone.today) }
      refused(/ck_bite_observations_outcome\b/) { bite_observation!(state: "closed", outcome: "healthy", outcome_on: nil) }
      refused(/ck_bite_observations_outcome_on/) { bite_observation!(state: "closed", outcome_on: Time.zone.today - 30) }
      refused(/ck_bite_observations_outcome_list/) { bite_observation!(state: "closed", outcome: "cured") }
      accepted { bite_observation!(state: "closed") }
    end

    it "observação closed → open → trigger; closed nunca muda; open → closed uma vez" do
      closed = bite_observation!(state: "closed")
      refused(/bite_observations: a closed observation never changes/) do
        raw_update(closed, state: "open", outcome: nil, outcome_on: nil, closed_by_user_id: nil)
      end
      refused(/bite_observations: a closed observation never changes/) { raw_update(closed, outcome: "died") }
      refused(/bite_observations: a closed observation never changes/) { raw_update(closed, place: "shelter") }
      accepted { raw_update(closed, animal_id: animal!.id, version: 2) } # §5: ligado a qualquer momento, uma vez
      refused(/bite_observations: animal_id never changes once set/) { raw_update(closed.reload, animal_id: animal!.id) }
      refused(/bite_observations: animal_id never changes once set/) { raw_update(closed.reload, animal_id: nil) }

      open = bite_observation!
      accepted { raw_update(open, animal_id: animal!.id, place: "shelter") }
      refused(/bite_observations: animal_id never changes once set/) { raw_update(open.reload, animal_id: animal!.id) }
      refused(/bite_observations: animal_id never changes once set/) { raw_update(open.reload, animal_id: nil) }
      accepted { raw_update(open, state: "closed", outcome: "healthy", outcome_on: Time.zone.today) }
      refused(/bite_observations: a closed observation never changes/) { raw_update(open, place: "home") }
    end

    it "DELETE e TRUNCATE recusados" do
      observation = bite_observation!
      refused(/bite_observations: DELETE refused/) { observation.delete }
      refused(/bite_observations is append-only: TRUNCATE refused/) { BiteObservation.connection.execute("TRUNCATE bite_observations CASCADE") }
    end
  end

  describe "leishmaniose" do
    let!(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(2)}", source: "manual") }
    let!(:block) { city_block!(neighborhood: neighborhood, number: "1") }

    it "inquérito: população e meta > 0, ao menos um quarteirão, parameters_version ≥ 0, versão ≥ 1" do
      refused(/ck_leish_surveys_dog_population/) { leish_survey!(blocks: block, dog_population: 0) }
      refused(/ck_leish_surveys_target_dogs/) { leish_survey!(blocks: block, target_dogs: 0) }
      refused(/ck_leish_surveys_blocks/) { leish_survey!(blocks: block, city_block_ids: []) }
      refused(/ck_leish_surveys_parameters_version/) { leish_survey!(blocks: block, parameters_version: -1) }
      refused(/ck_leish_surveys_version/) { leish_survey!(blocks: block, version: 0) }
      refused(/ck_leish_surveys_kind/) { leish_survey!(blocks: block, kind: "random") }
      accepted { leish_survey!(blocks: block, parameters_version: 0) }
    end

    it "etapa do inquérito só draft → open → closed; DELETE recusado" do
      survey = leish_survey!(blocks: block, stage: "draft")
      refused(/leish_surveys: the stage only goes draft → open → closed/) { raw_update(survey, stage: "closed") }
      accepted { raw_update(survey, stage: "open") }
      refused(/leish_surveys: the stage only goes draft → open → closed/) { raw_update(survey, stage: "draft") }
      accepted { raw_update(survey, stage: "closed") }
      refused(/leish_surveys: the stage only goes draft → open → closed/) { raw_update(survey, stage: "open") }
      refused(/leish_surveys: DELETE refused/) { survey.delete }
    end

    it "ELISA com DPP non_reactive (ou sem DPP) → CHECK; com DPP reactive passa" do
      refused(/ck_leish_tests_elisa_after_dpp/) { leish_test!(dpp_result: "non_reactive", elisa_result: "reactive") }
      refused(/ck_leish_tests_elisa_after_dpp/) { leish_test!(dpp_result: nil, elisa_result: "reactive") }
      refused(/ck_leish_tests_dpp_result/) { leish_test!(dpp_result: "maybe") }
      accepted { leish_test!(dpp_result: "reactive", elisa_result: "inconclusive") }
    end

    it "etiqueta única; client_uuid único entre os não nulos; DELETE recusado" do
      test = leish_test!
      expect { leish_test!(label: test.label) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_leish_tests_label/)
      uuid = SecureRandom.uuid
      leish_test!(client_uuid: uuid)
      expect { leish_test!(client_uuid: uuid) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_leish_tests_client_uuid/)
      expect { 2.times { leish_test!(client_uuid: nil) } }.not_to raise_error
      refused(/leish_tests is append-only: DELETE refused/) { test.delete }
      accepted { raw_update(test, dpp_result: "reactive") }
    end

    it "desfecho euthanasia sem euthanasia_id → CHECK; com ele passa; sem euthanasia exige null" do
      test = leish_test!(dpp_result: "reactive", elisa_result: "reactive")
      refused(/ck_leish_dog_outcomes_euthanasia/) { LeishDogOutcome.create!(outcome_attrs(test, decision: "euthanasia")) }
      euthanasia = euthanasia!(animal: test.animal, by: vet, reason: "leishmaniasis")
      refused(/ck_leish_dog_outcomes_euthanasia/) { LeishDogOutcome.create!(outcome_attrs(test, decision: "refused", euthanasia: euthanasia)) }
      accepted { LeishDogOutcome.create!(outcome_attrs(test, decision: "euthanasia", euthanasia: euthanasia)) }
      expect(Euthanasia.column_names).not_to include("leish_dog_outcome_id")
    end

    it "um desfecho por exame; só acréscimo (UPDATE e DELETE recusados)" do
      test = leish_test!(dpp_result: "reactive", elisa_result: "reactive")
      outcome = LeishDogOutcome.create!(outcome_attrs(test))
      expect { LeishDogOutcome.create!(outcome_attrs(test, decision: "tutor_treatment")) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_leish_dog_outcomes_test/)
      refused(/leish_dog_outcomes is append-only: UPDATE refused/) { raw_update(outcome, decision: "tutor_treatment") }
      refused(/leish_dog_outcomes is append-only: DELETE refused/) { outcome.delete }
      refused(/leish_dog_outcomes is append-only: TRUNCATE refused/) { LeishDogOutcome.connection.execute("TRUNCATE leish_dog_outcomes CASCADE") }
    end
  end

  describe "canil, castração e eutanásia" do
    it "duas estadas abertas do animal → único; a saída libera" do
      animal = animal!
      first = stay!(animal: animal)
      expect { stay!(animal: animal) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_shelter_stays_open/)
      accepted { raw_update(first, exit_kind: "returned", exited_on: Time.zone.today) }
      expect { stay!(animal: animal) }.not_to raise_error
    end

    it "adotante em saída returned → CHECK; em adopted passa" do
      adopter = tutor!
      stay = stay!
      refused(/ck_shelter_stays_adopter/) { raw_update(stay, exit_kind: "returned", exited_on: Time.zone.today, adopter_patient_id: adopter.id) }
      accepted { raw_update(stay, exit_kind: "adopted", exited_on: Time.zone.today, adopter_patient_id: adopter.id) }
    end

    it "saída ⇔ dia; observação só na entrada observation; saída não antes da entrada" do
      refused(/ck_shelter_stays_exit\b/) { stay!(exit_kind: "returned", exited_on: nil) }
      refused(/ck_shelter_stays_exit\b/) { stay!(exit_kind: nil, exited_on: Time.zone.today) }
      refused(/ck_shelter_stays_period/) { stay!(exit_kind: "returned", exited_on: Time.zone.today - 5) }
      refused(/ck_shelter_stays_observation/) { stay!(bite_observation: bite_observation!(place: "shelter"), entry_kind: "collection") }
      accepted { stay!(bite_observation: bite_observation!(place: "shelter"), entry_kind: "observation") }
      refused(/ck_shelter_stays_entry_kind/) { stay!(entry_kind: "pound") }
    end

    it "estada: só a saída muda, uma vez; DELETE recusado" do
      stay = stay!
      refused(/shelter_stays: only the exit changes/) { raw_update(stay, entered_on: Time.zone.today - 1) }
      refused(/shelter_stays: only the exit changes/) { raw_update(stay, entry_kind: "other") }
      accepted { raw_update(stay, exit_kind: "transferred", exited_on: Time.zone.today, version: 2) }
      refused(/shelter_stays: a stay is closed once/) { raw_update(stay, exit_kind: "death") }
      refused(/shelter_stays: DELETE refused/) { stay.delete }
    end

    it "castração: uma por animal; só acréscimo" do
      animal = animal!
      attrs = { animal: animal, performed_on: Time.zone.today, professional: vet.professional }
      neutering = Neutering.create!(attrs)
      expect { Neutering.create!(attrs) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_neuterings_animal/)
      refused(/neuterings is append-only: UPDATE refused/) { raw_update(neutering, performed_on: Time.zone.today - 1) }
      refused(/neuterings is append-only: DELETE refused/) { neutering.delete }
      refused(/neuterings is append-only: TRUNCATE refused/) { Neutering.connection.execute("TRUNCATE neuterings CASCADE") }
    end

    it "eutanásia sem base legal ou com base fora da lista → CHECK" do
      refused(/ck_euthanasias_legal_basis/) { euthanasia!(animal: animal!, by: vet, legal_basis: []) }
      refused(/ck_euthanasias_legal_basis/) { euthanasia!(animal: animal!, by: vet, legal_basis: %w[cfmv_1000_2012 other_law]) }
      refused(/ck_euthanasias_legal_basis/) { euthanasia!(animal: animal!, by: vet, legal_basis: %w[other_law]) }
      accepted { euthanasia!(animal: animal!, by: vet, legal_basis: %w[cfmv_1000_2012 law_14228_2021]) }
      refused(/ck_euthanasias_reason/) { euthanasia!(animal: animal!, by: vet, reason: "boredom") }
    end

    it "eutanásia sem nota do motivo → NOT NULL" do
      refused(/null value in column "reason_note"/) { euthanasia!(animal: animal!, by: vet, reason_note: nil) }
    end

    it "UPDATE e DELETE de eutanásia → trigger; TRUNCATE também" do
      euthanasia = euthanasia!(animal: animal!, by: vet)
      refused(/euthanasias is append-only: UPDATE refused/) { raw_update(euthanasia, reason: "other") }
      refused(/euthanasias is append-only: UPDATE refused/) { raw_update(euthanasia, performed_on: Time.zone.today - 1) }
      refused(/euthanasias is append-only: DELETE refused/) { euthanasia.delete }
      refused(/euthanasias is append-only: TRUNCATE refused/) { Euthanasia.connection.execute("TRUNCATE euthanasias CASCADE") }
    end

    it "a re-cifra da nota da eutanásia passa; outra coluna na mesma escrita não" do
      euthanasia = euthanasia!(animal: animal!, by: vet)
      accepted do
        CityEncryption.allowing_reencryption { Euthanasia.where(id: euthanasia.id).update_all(reason_note: "texto recifrado") }
      end
      refused(/euthanasias is append-only: UPDATE refused/) do
        CityEncryption.allowing_reencryption { Euthanasia.where(id: euthanasia.id).update_all(reason_note: "x", reason: "other") }
      end
    end

    it "segunda eutanásia do animal → único" do
      animal = animal!
      euthanasia!(animal: animal, by: vet)
      expect { euthanasia!(animal: animal, by: vet) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_euthanasias_animal/)
    end

    it "eutanásia e estada de um animal missing não esbarram em nenhuma regra do banco (Q31)" do
      missing = animal!(status: "missing", status_on: Time.zone.today)
      accepted { stay!(animal: missing) }
      accepted { euthanasia!(animal: missing, by: vet) }
    end
  end

  describe "demanda de zoonoses" do
    it "segunda demanda do encaminhamento → único" do
      forwarding = forwarding!
      demand!(forwarding: forwarding)
      expect { demand!(forwarding: forwarding) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_zoonoses_demands_forwarding/)
    end

    it "subtipo e estado no domínio; versão ≥ 1; resultado só com closed" do
      refused(/ck_zoonoses_demands_subtype/) { demand!(subtype: "dragon") }
      refused(/ck_zoonoses_demands_state/) { demand!(state: "reopened") }
      refused(/ck_zoonoses_demands_version/) { demand!(version: 0) }
      refused(/ck_zoonoses_demands_outcome\b/) { demand!(state: "inspected", outcome: "resolved") }
      refused(/ck_zoonoses_demands_outcome_list/) { demand!(state: "closed", outcome: "cured") }
      accepted { demand!(state: "closed", outcome: "resolved") }
      accepted { demand!(state: "closed", outcome: nil) } # recusada pela unidade (§4)
    end

    it "o estado não volta; DELETE e TRUNCATE recusados" do
      demand = demand!
      accepted { raw_update(demand, state: "scheduled", scheduled_on: Time.zone.today) }
      accepted { raw_update(demand, state: "scheduled", version: 2) }
      accepted { raw_update(demand, state: "inspected") }
      refused(/zoonoses_demands: the state never goes back/) { raw_update(demand, state: "scheduled") }
      refused(/zoonoses_demands: the state never goes back/) { raw_update(demand, state: "open") }
      accepted { raw_update(demand, state: "closed", outcome: "guidance") }
      refused(/zoonoses_demands: the state never goes back/) { raw_update(demand, state: "inspected", outcome: nil) }
      refused(/zoonoses_demands: DELETE refused/) { demand.delete }
      refused(/zoonoses_demands is append-only: TRUNCATE refused/) { ZoonosesDemand.connection.execute("TRUNCATE zoonoses_demands CASCADE") }
    end

    it "a nota da inspeção é cifrada e a re-cifra passa pelo trigger" do
      demand = demand!(state: "inspected", inspection_note: "Escorpião amarelo achado no quintal.")
      expect(demand.reload.inspection_note).to eq("Escorpião amarelo achado no quintal.")
      expect(ZoonosesDemand.connection.select_value("SELECT inspection_note FROM zoonoses_demands WHERE id = '#{demand.id}'"))
        .not_to include("Escorpião")
      accepted do
        CityEncryption.allowing_reencryption { ZoonosesDemand.where(id: demand.id).update_all(inspection_note: "recifrado") }
      end
    end

    it "o inspect dos modelos só traz o id e o estado" do
      block = city_block!(neighborhood: Neighborhood.create!(name: "B#{SecureRandom.hex(2)}", source: "manual"), number: "1")
      neutering = Neutering.create!(animal: animal!, performed_on: Time.zone.today, professional: vet.professional)
      outcome = LeishDogOutcome.create!(outcome_attrs(leish_test!))
      [ demand!, bite_observation!, leish_survey!(blocks: block), leish_test!, stay!, euthanasia!(animal: animal!, by: vet), neutering,
        outcome ].each do |record|
        expect(record.inspect).to eq(record.to_s)
        expect(record.inspect).to match(/\A#<#{record.class.name} id=#{record.id}( \w+=\w+)?>\z/)
        expect(record.as_json.keys).to all(satisfy { |key| %w[id state stage open decision].include?(key) })
      end
    end
  end

  describe "field-sync" do
    let!(:team) { registry_team! }
    let!(:agent) { field_agent!(team: team) }
    let!(:device) do
      FieldDevice.create!(user: agent, professional: agent.professional, name: "Tablet da UVZ",
                          token_digest: FieldDevice.digest("rsf_#{SecureRandom.urlsafe_base64(32)}"))
    end
    let!(:area) { registry_micro_area!(team: team, code: "01") }

    def receipt(item_type)
      FieldSyncReceipt.new(client_uuid: SecureRandom.uuid, field_device: device, user: agent, item_type: item_type,
                           result_type: "Animal", result_id: SecureRandom.uuid)
    end

    def tombstone(entity_type, reason)
      FieldSyncTombstone.new(entity_type: entity_type, entity_id: SecureRandom.uuid, micro_area: area, reason: reason)
    end

    it "recibo animal, rabies_vaccination, leish_collection e collar aceitos; fora da lista → CHECK" do
      %w[animal rabies_vaccination leish_collection collar home_visit ovitrap_collection].each do |type|
        accepted { receipt(type).save!(validate: false) }
      end
      refused(/ck_field_sync_receipts_item_type/) { receipt("shelter_stay").save!(validate: false) }
    end

    it "lápides animal e leish_survey com out_of_scope aceitas (Q21); o resto segue recusado" do
      accepted { tombstone("animal", "out_of_scope").save!(validate: false) }
      accepted { tombstone("leish_survey", "out_of_scope").save!(validate: false) }
      accepted { tombstone("household", "out_of_scope").save!(validate: false) }
      accepted { tombstone("animal", "moved").save!(validate: false) }
      refused(/ck_field_sync_tombstones_entity_type/) { tombstone("collar", "moved").save!(validate: false) }
      refused(/ck_field_sync_tombstones_reason/) { tombstone("animal", "gone").save!(validate: false) }
    end
  end
end
