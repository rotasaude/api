require "rails_helper"

# Módulo 35b, Task 17 (ADR 0054; contrato §11, §12, Q19, Q20, Q21, Q22, Q29,
# Q36): o envio do app de campo na v1.4.0. Os itens animal, rabies_vaccination,
# leish_collection e collar, só com Zoonoses::Gate.field_usable? (lido fora da
# transação; desligado → feature_disabled):
#   - animal → Zoonoses::SaveAnimal(origin: "field") com o corpo inteiro (Q20):
#     tutor por tutor_patient_id ou tutor_client_uuid (o paciente criado no
#     mesmo lote por um patient ou por um individual_registration com
#     new_patient, Q29; senão tutor_not_found); accepted com version; edição
#     vencida → stale_version com o <animal> atual (24c), sem mescla;
#   - rabies_vaccination (modalidade house), leish_collection (etiqueta do api,
#     maiúscula, no accepted e no duplicate, Q21/Q36) e collar citam o animal
#     por animal_id ou animal_client_uuid (o livro);
#   - a falta de estoque não é recusa; a segunda dose na campanha só o api
#     barra (Q19).
# Reenvio de um item aceito → duplicate com o mesmo id (o livro), nunca 500.
# Toda resposta validada contra o upload-response-v1 da v1.4.0.
RSpec.describe "FieldSync::Upload — zoonoses (v1.4.0)", type: :model do
  let!(:city) { zoonoses_city! }
  let(:today) { Time.zone.today }
  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:device) { FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:device) }
  let(:household) { registry_household!(micro_area: area) }
  let(:vaccine) { zoonoses_product!(code: "RAB") }
  let(:collar_product) { zoonoses_product!(use: "collar", code: "COL") }
  let(:campaign) do
    RabiesCampaign.create!(name: "Campanha #{SecureRandom.hex(3)}", year: today.year, starts_on: today - 5, ends_on: today + 20,
                           goal_dogs: 10, goal_cats: 5, stage: "open")
  end

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def item(type, body, uuid: SecureRandom.uuid) = { "client_uuid" => uuid, "type" => type, "body" => body }
  def upload(*items, user: acs, dev: device) = FieldSync::Upload.call(items: items, device: dev, user: user)
  def failure(result) = result.slice("status", "error", "path")
  def statuses(results) = results.map { _1["status"] }
  def field_trail = DomainEvent.where(name: "clinical_record.viewed").select { |event| event.payload["access"] == "field_sync" }

  def valid_response!(results)
    expect(FieldSync::Schemas.errors("upload-response-v1", { "results" => results }.as_json)).to eq([])
  end

  def typed(name = "Benedita Alves Rocha", birth_date: "1951-03-08")
    { "full_name" => name, "birth_date" => birth_date, "sex" => "female", "no_cpf_reason" => "3" }
  end

  def animal_body(**over)
    { "household_id" => household.id, "species" => "dog", "sex" => "female", "community" => false }.merge(over.stringify_keys)
  end

  def vaccination_body(**over)
    { "campaign_id" => campaign.id, "vaccinated_on" => today.iso8601, "vector_product_id" => vaccine.id,
      "adverse_event" => false }.merge(over.stringify_keys)
  end

  def collar_body(**over)
    { "vector_product_id" => collar_product.id, "placed_on" => today.iso8601 }.merge(over.stringify_keys)
  end

  def gate_off!
    Platform::Features.set!(city: Current.city, key: Zoonoses::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
  end

  it "lote patient → animal (tutor_client_uuid) → rabies_vaccination (animal_client_uuid) → collar → todos accepted, em ordem; reenvio → duplicate" do
    patient_uuid, animal_uuid = SecureRandom.uuid, SecureRandom.uuid
    batch = [ item("patient", { "new_patient" => typed }, uuid: patient_uuid),
              item("animal", animal_body(tutor_client_uuid: patient_uuid, name: "Bidu", size: "medium", coat: "Caramelo",
                                         breed: "SRD", birth_estimate_month: "2024-03", microchip: "985112345678903",
                                         registry_number: "UVZ-77"), uuid: animal_uuid),
              item("rabies_vaccination", vaccination_body(animal_client_uuid: animal_uuid)),
              item("collar", collar_body(animal_client_uuid: animal_uuid)) ]
    results = upload(*batch)
    valid_response!(results)
    expect(statuses(results)).to eq(%w[accepted accepted accepted accepted])
    expect(results.map { _1["type"] }).to eq(%w[patient animal rabies_vaccination collar])

    animal = Animal.find(results[1]["id"])
    expect(results[1]).to include("version" => 1)
    expect(animal).to have_attributes(household_id: household.id, tutor_patient_id: results[0]["id"], community: false, name: "Bidu",
                                      birth_estimate_on: Date.new(2024, 3, 1), microchip: "985112345678903", status: "active",
                                      created_by_user_id: acs.id)
    vaccination = RabiesVaccination.find(results[2]["id"])
    expect(vaccination).to have_attributes(animal_id: animal.id, modality: "house", campaign_id: campaign.id, household_id: household.id,
                                           client_uuid: batch[2]["client_uuid"], species: "dog", recorded_by_user_id: acs.id)
    collar = Collar.find(results[3]["id"])
    expect(collar).to have_attributes(animal_id: animal.id, placed_on: today, due_on: today >> 6, client_uuid: batch[3]["client_uuid"])
    # Sem local de estoque: a falta fica, o registro não é recusado (§3).
    expect(VectorStockShortfall.pluck(:source)).to contain_exactly("vaccination", "collar")
    expect(results.flat_map(&:keys)).not_to include("label")
    expect(results.drop(2).flat_map(&:keys)).not_to include("version")
    expect(FieldSyncReceipt.where(item_type: %w[animal rabies_vaccination collar]).order(:created_at).pluck(:result_type, :result_version))
      .to eq([ [ "Animal", 1 ], [ "RabiesVaccination", nil ], [ "Collar", nil ] ])

    again = upload(*batch)
    valid_response!(again)
    expect(statuses(again)).to eq(%w[duplicate duplicate duplicate duplicate])
    expect(again.map { _1["id"] }).to eq(results.map { _1["id"] })
    expect(again[1]).to include("version" => 1)
    expect([ Animal.count, RabiesVaccination.count, Collar.count ]).to eq([ 1, 1, 1 ])
  end

  it "Q29: tutor_client_uuid de um individual_registration com new_patient → o paciente do cadastro; uuid sem item → tutor_not_found" do
    registration_uuid = SecureRandom.uuid
    sections = registry_registration_sections.deep_stringify_keys
    sections["identification"] = sections["identification"].merge("desconhece_nome_mae" => true)
    registration = sections.merge("is_responsible" => false, "household_id" => household.id, "new_patient" => typed("Rosalina Prado Lopes"),
                                  "patient_demographics" => { "race_color" => "01", "ethnicity" => nil })
    results = upload(item("individual_registration", registration, uuid: registration_uuid),
                     item("animal", animal_body(tutor_client_uuid: registration_uuid)),
                     item("animal", animal_body(tutor_client_uuid: SecureRandom.uuid)),
                     item("animal", animal_body(household_client_uuid: SecureRandom.uuid).except("household_id")))
    valid_response!(results)
    expect(statuses(results).first(2)).to eq(%w[accepted accepted])
    patient_id = IndividualRegistration.find(results[0]["id"]).patient_id
    expect(Animal.find(results[1]["id"]).tutor_patient_id).to eq(patient_id)
    expect(results.drop(2).map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "tutor_not_found", "path" => "tutor_client_uuid" },
                                                        { "status" => "rejected", "error" => "not_found", "path" => "household_client_uuid" } ])
    expect(Animal.count).to eq(1)
  end

  it "domicílio fora do escopo → out_of_scope; animal de outro usuário não vale como animal_client_uuid" do
    outside = registry_household!
    animal_uuid = SecureRandom.uuid
    other = field_agent!(team: outside.micro_area.team)
    outside.micro_area.update!(acs_professional: other.professional)
    other_device = FieldDevices::Register.call(user: other, name: "Tablet").payload.fetch(:device)
    expect(upload(item("animal", animal_body(household_id: outside.id), uuid: animal_uuid), user: other, dev: other_device).sole["status"])
      .to eq("accepted")

    results = upload(item("animal", animal_body(household_id: outside.id)), item("collar", collar_body(animal_client_uuid: animal_uuid)))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "out_of_scope" },
                                                { "status" => "rejected", "error" => "not_found", "path" => "animal_client_uuid" } ])
  end

  it "leish_collection do ACE → accepted com label LV-… em maiúsculas; reenvio → duplicate com o mesmo label; do ACS → cbo_not_allowed; fora do inquérito → household_not_in_survey" do
    ace = endemic_agent!(team: team)
    ace_area = MicroAreaFieldAssignment.active.find_by!(professional_id: ace.professional.id).micro_area
    ace_device = FieldDevices::Register.call(user: ace, name: "Tablet").payload.fetch(:device)
    neighborhood = Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual")
    block = city_block!(neighborhood: neighborhood, number: "1")
    far = city_block!(neighborhood: neighborhood, number: "9")
    home = registry_household!(micro_area: ace_area).tap { vector_profile!(_1, block: block) }
    away = registry_household!(micro_area: ace_area).tap { vector_profile!(_1, block: far) }
    survey = leish_survey!(blocks: [ block ], starts_on: today - 5)
    dog = animal!(household: home)
    stray = animal!(household: away)
    acs_dog = animal!(household: household)

    uuid = SecureRandom.uuid
    sent = item("leish_collection", { "leish_survey_id" => survey.id, "animal_id" => dog.id, "collected_on" => today.iso8601,
                                      "dpp_result" => "reactive", "dpp_on" => today.iso8601 }, uuid: uuid)
    first = upload(sent, user: ace, dev: ace_device).sole
    valid_response!([ first ])
    test = LeishTest.sole
    expect(first).to eq("client_uuid" => uuid, "status" => "accepted", "type" => "leish_collection", "id" => test.id,
                        "label" => "LV-#{today.year}-#{survey.id.delete('-')[0, 6].upcase}-0001")
    expect(first["label"]).to match(/\ALV-[0-9]{4}-([0-9A-F]{6}|AVUL)-[0-9]{4,6}\z/)
    expect(test).to have_attributes(animal_id: dog.id, client_uuid: uuid, dpp_result: "reactive", result_by_user_id: ace.id)

    again = upload(sent, user: ace, dev: ace_device).sole
    valid_response!([ again ])
    expect(again).to eq(first.merge("status" => "duplicate"))

    loose = upload(item("leish_collection", { "animal_id" => dog.id, "collected_on" => today.iso8601 }), user: ace, dev: ace_device).sole
    expect(loose).to include("status" => "accepted", "label" => "LV-#{today.year}-AVUL-0001")

    refused = [ upload(item("leish_collection", { "leish_survey_id" => survey.id, "animal_id" => stray.id, "collected_on" => today.iso8601 }),
                       user: ace, dev: ace_device).sole,
                upload(item("leish_collection", { "animal_id" => acs_dog.id, "collected_on" => today.iso8601 })).sole ]
    valid_response!(refused)
    expect(refused.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "household_not_in_survey", "path" => "leish_survey_id" },
                                                { "status" => "rejected", "error" => "cbo_not_allowed" } ])
    expect(refused.flat_map(&:keys)).not_to include("label")
    expect(LeishTest.count).to eq(2)
  end

  it "edição do animal com version velha → stale_version com current_version e o <animal> atual, com a trilha do tutor" do
    tutor = tutor!
    animal = animal!(household: household, tutor: tutor, microchip: "985112345678903", name: "Rex")
    edit = ->(version, **over) { item("animal", animal_body(animal_id: animal.id, version: version, name: "Rex", **over)) }

    ok = upload(edit.call(1, tutor_patient_id: tutor.id, coat: "Preto")).sole
    valid_response!([ ok ])
    expect(ok).to include("status" => "accepted", "id" => animal.id, "version" => 2)
    expect(animal.reload).to have_attributes(coat: "Preto", version: 2, tutor_patient_id: tutor.id)

    # Corpo inteiro (D4): o tutor ausente sai; ausente não é "manter".
    stale = upload(edit.call(1, breed: "SRD")).sole
    valid_response!([ stale ])
    expect(stale).to include("status" => "stale_version", "id" => animal.id, "current_version" => 2)
    expect(stale.fetch("current")).to include("id" => animal.id, "version" => 2, "coat" => "Preto", "has_microchip" => true,
                                              "tutor" => { "patient_id" => tutor.id, "display_name" => tutor.display_name })
    expect(stale.to_json).not_to include("985112345678903")
    expect(animal.reload).to have_attributes(breed: nil, version: 2)
    expect(field_trail.last.payload).to include("household_ids" => [ household.id ], "patient_ids" => [ tutor.id ])

    cleared = upload(edit.call(2)).sole
    expect(cleared).to include("status" => "accepted", "version" => 3)
    expect(animal.reload).to have_attributes(tutor_patient_id: nil, coat: nil, microchip: "985112345678903")
  end

  it "edição pelo app: mudança para outro domicílio do escopo → accepted; para fora → out_of_scope; animal em estado final → animal_not_active" do
    animal = animal!(household: household)
    neighbor = registry_household!(micro_area: area)
    moved = upload(item("animal", animal_body(animal_id: animal.id, version: 1, household_id: neighbor.id))).sole
    expect(moved).to include("status" => "accepted", "version" => 2)
    expect(animal.reload.household_id).to eq(neighbor.id)

    outside = upload(item("animal", animal_body(animal_id: animal.id, version: 2, household_id: registry_household!.id))).sole
    expect(failure(outside)).to eq("status" => "rejected", "error" => "out_of_scope")

    gone = upload(item("animal", animal_body(animal_id: animal.id, version: 2, household_id: neighbor.id, status: "transferred",
                                             status_on: today.iso8601))).sole
    expect(gone).to include("status" => "accepted", "version" => 3)
    expect(animal.reload).to have_attributes(status: "transferred", status_on: today)

    final = upload(item("animal", animal_body(animal_id: animal.id, version: 3, household_id: neighbor.id))).sole
    valid_response!([ moved, outside, gone, final ])
    expect(failure(final)).to eq("status" => "rejected", "error" => "animal_not_active")

    unknown = upload(item("animal", animal_body(animal_id: SecureRandom.uuid, version: 1))).sole
    expect(failure(unknown)).to eq("status" => "rejected", "error" => "not_found", "path" => "animal_id")
  end

  it "vacinação com data futura → date_out_of_range path vaccinated_on; antes da campanha também; produto de coleira → product_not_allowed" do
    dog = animal!(household: household)
    results = upload(item("rabies_vaccination", vaccination_body(animal_id: dog.id, vaccinated_on: (today + 1).iso8601)),
                     item("rabies_vaccination", vaccination_body(animal_id: dog.id, vaccinated_on: (today - 6).iso8601)),
                     item("rabies_vaccination", vaccination_body(animal_id: dog.id, vector_product_id: collar_product.id)),
                     item("collar", collar_body(animal_id: dog.id, placed_on: (today + 1).iso8601)))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "date_out_of_range", "path" => "vaccinated_on" },
                                                { "status" => "rejected", "error" => "date_out_of_range", "path" => "vaccinated_on" },
                                                { "status" => "rejected", "error" => "product_not_allowed", "path" => "vector_product_id" },
                                                { "status" => "rejected", "error" => "date_out_of_range", "path" => "placed_on" } ])
    expect(RabiesVaccination.count + Collar.count).to eq(0)
  end

  it "microchip repetido → rejected microchip_taken path microchip; registro repetido → registry_number_taken" do
    animal!(household: household, microchip: "985112345678903", registry_number: "UVZ-1")
    results = upload(item("animal", animal_body(microchip: "985112345678903")), item("animal", animal_body(registry_number: "uvz-1")))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "microchip_taken", "path" => "microchip" },
                                                { "status" => "rejected", "error" => "registry_number_taken", "path" => "registry_number" } ])
    expect(results.to_json).not_to include("985112345678903")
    expect(Animal.count).to eq(1)
  end

  it "segunda dose na campanha → rejected already_vaccinated_in_campaign, sem segunda baixa; campanha não open → campaign_not_open" do
    dog = animal!(household: household)
    first = upload(item("rabies_vaccination", vaccination_body(animal_id: dog.id))).sole
    second = upload(item("rabies_vaccination", vaccination_body(animal_id: dog.id))).sole
    planned = RabiesCampaign.create!(name: "Próxima", year: today.year, starts_on: today + 30, ends_on: today + 60, stage: "planned")
    third = upload(item("rabies_vaccination", vaccination_body(animal_id: dog.id, campaign_id: planned.id))).sole
    valid_response!([ first, second, third ])
    expect(first["status"]).to eq("accepted")
    expect(failure(second)).to eq("status" => "rejected", "error" => "already_vaccinated_in_campaign")
    expect(failure(third)).to eq("status" => "rejected", "error" => "campaign_not_open", "path" => "campaign_id")
    expect([ RabiesVaccination.count, VectorStockShortfall.count ]).to eq([ 1, 1 ])
  end

  it "coleira em gato → rejected animal_not_dog; coleira sem saldo → accepted com a falta; a ativa anterior sai replaced" do
    cat = animal!(household: household, species: "cat")
    dog = animal!(household: household)
    location = vector_location!
    vector_stock_location!(location)
    vector_lot!(location, product: collar_product, quantity: "1")
    results = upload(item("collar", collar_body(animal_id: cat.id)), item("collar", collar_body(animal_id: dog.id)),
                     item("collar", collar_body(animal_id: dog.id)))
    valid_response!(results)
    expect(failure(results[0])).to eq("status" => "rejected", "error" => "animal_not_dog")
    expect(statuses(results).drop(1)).to eq(%w[accepted accepted])
    expect(Collar.where(animal_id: dog.id).order(:created_at).map { [ _1.removal_reason, _1.removed_on ] }).to eq([ [ "replaced", today ], [ nil, nil ] ])
    expect(VectorStockShortfall.sole).to have_attributes(source: "collar", collar_id: results[2]["id"])
  end

  it "gate desligado → os quatro itens rejected feature_disabled, nada gravado" do
    dog = animal!(household: household)
    gate_off!
    results = upload(item("animal", animal_body), item("rabies_vaccination", vaccination_body(animal_id: dog.id)),
                     item("leish_collection", { "animal_id" => dog.id, "collected_on" => today.iso8601 }),
                     item("collar", collar_body(animal_id: dog.id)))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "feature_disabled" } ] * 4)
    expect([ Animal.count, RabiesVaccination.count, LeishTest.count, Collar.count, FieldSyncReceipt.count ]).to eq([ 1, 0, 0, 0, 0 ])
  end

  it "fora do esquema: tutor com community true e microchip na edição → invalid_request com o path" do
    animal = animal!(household: household)
    results = upload(item("animal", animal_body(community: true, tutor_patient_id: tutor!.id)),
                     item("animal", animal_body(animal_id: animal.id, version: 1, microchip: "985112345678903")),
                     item("rabies_vaccination", vaccination_body(animal_id: animal.id, adverse_note: "Inchaço no local da dose.")))
    valid_response!(results)
    expect(results.map { _1.slice("status", "error") }).to eq([ { "status" => "rejected", "error" => "invalid_request" } ] * 3)
    expect(results.map { _1["path"] }).to all(be_present)
  end

  it "exemplos v1.3.0 seguem aceitos: o envio do ACS sem item novo, numa cidade com zoonoses, como antes" do
    manifest = JSON.parse(File.read(Rails.root.join("spec/fixtures/field_sync/examples/manifest.json")))
    old_types = %w[home_visit home_visit_withdrawal collective_activity patient household individual_registration family
                   ovitrap_installation ovitrap_collection]
    valid = manifest.fetch("suites").find { _1.fetch("schema") == "upload-request-v1.json" }.fetch("cases").select { _1["expect"] == "valid" }
    old = valid.map { JSON.parse(File.read(Rails.root.join("spec/fixtures/field_sync/examples", _1.fetch("file")))) }
               .select { |doc| doc.fetch("items").all? { old_types.include?(_1["type"]) } }
    expect(old.size).to be >= 10
    expect(old.map { FieldSync::Schemas.errors("upload-request-v1", _1) }.uniq).to eq([ [] ])

    visit = { "team_id" => team.id, "occurred_at" => Time.current.change(usec: 0).iso8601, "micro_area_id" => area.id, "property_type" => "1",
              "subject" => "none", "outcome" => 1, "reasons" => [ 1 ], "shared" => false }
    results = upload(item("patient", { "new_patient" => typed }), item("home_visit", visit))
    valid_response!(results)
    expect(statuses(results)).to eq(%w[accepted accepted])
    expect(results.flat_map(&:keys)).not_to include("label", "version")
  end
end
