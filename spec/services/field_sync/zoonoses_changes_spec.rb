require "rails_helper"

# Módulo 35b, Task 17 (ADR 0054; contrato §11; Q9, Q20, Q21; plano, Review
# Focus 5): o download do app de campo na v1.4.0. SÓ com
# Zoonoses::Gate.field_usable? o fluxo ganha:
#   - animal: os active dos domicílios do escopo, com has_microchip (nunca o
#     número), o tutor só { patient_id, display_name }, last_rabies_vaccination_on
#     e collar_due_on (a coleira ATIVA); dose, anulação e coleira reemitem o
#     animal com a mesma version (Q20, Q29 do 35a);
#   - leish_survey: os open que cruzam os quarteirões dos perfis dos
#     domicílios do escopo, com household_ids (os do escopo) no lugar de
#     city_block_ids (Q21).
# O animal que sai do escopo ou de active e o inquérito que fecha saem em
# removals out_of_scope (lápides, uma por microárea). O interruptor entra no
# scope_digest: ligar ou desligar com cursor antigo → reset: true. Página com
# tutor grava a trilha clinical_record.viewed access field_sync. Toda página
# validada contra o changes-response-v1 da v1.4.0.
RSpec.describe "FieldSync::Changes — zoonoses (v1.4.0)", type: :model do
  def max_pages = 12

  let!(:city) { zoonoses_city! }
  let(:today) { Time.zone.today }
  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:device) { FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:device) }
  let(:household) { registry_household!(micro_area: area) }
  let(:team_member) { zoonoses_team! }
  let(:coordinator) { zoonoses_coordinator! }
  let(:neighborhood) { Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def fetch(cursor = nil, limit: 200)
    FieldSync::Changes.page(user: acs, device: device, cursor: cursor, limit: limit, now: Time.current + 3.seconds)
  end

  def all_pages(cursor = nil, limit: 200)
    pages = []
    max_pages.times do
      page = JSON.parse(fetch(cursor, limit: limit).to_json)
      expect(FieldSync::Schemas.errors("changes-response-v1", page)).to eq([])
      pages << page
      cursor = page.fetch("next_cursor")
      return pages unless page.fetch("has_more")
    end
    raise "paginação passou de #{max_pages} páginas"
  end

  def items(pages) = pages.flat_map { _1.fetch("items") }
  def of(pages, type) = items(pages).select { _1.fetch("type") == type }
  def refs(pages, type) = of(pages, type).map { _1.fetch("id") }
  def body_of(pages, type, id) = of(pages, type).find { _1.fetch("id") == id }&.fetch("body")
  def removals(pages) = pages.flat_map { _1.fetch("removals") }
  def zoonoses_types = %w[animal leish_survey]
  def last_cursor(pages) = pages.last.fetch("next_cursor")

  def gate!(enabled)
    Platform::Features.set!(city: Current.city, key: Zoonoses::Gate::KEY, enabled: enabled, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
  end

  def edit(animal, **params)
    Zoonoses::SaveAnimal.call(animal: animal, by: team_member, params: { "expected_version" => animal.reload.version }.merge(params.stringify_keys))
  end

  describe "Review Focus 5" do
    it "cursor antigo e zoonoses ligado → reset true com os animais antigos; desligar com cursor antigo → reset true sem tipo novo" do
      animal = animal!(household: household)
      gate!(false)
      off = all_pages
      expect(items(off).map { _1["type"] } & zoonoses_types).to eq([])
      cursor = last_cursor(off)
      expect(fetch(cursor)).to include(reset: false, items: [])

      gate!(true)
      on = all_pages(cursor)
      expect(on.first.fetch("reset")).to be(true)
      expect(refs(on, "animal")).to eq([ animal.id ])
      expect(refs(on, "household")).to include(household.id)
      expect(fetch(last_cursor(on))).to include(reset: false, items: [])

      gate!(false)
      again = all_pages(last_cursor(on))
      expect(again.first.fetch("reset")).to be(true)
      expect(items(again).map { _1["type"] } & zoonoses_types).to eq([])
      expect(removals(again).map { _1["type"] } & zoonoses_types).to eq([])
    end

    it "o interruptor muda o scope_digest; desligado, o digest é o da v1.3.0" do
      v13 = FieldSync::Scope.for(acs, vector_control: false)
      expect(FieldSync::Scope.for(acs, vector_control: false, zoonoses: false)).to eq(v13)
      on = FieldSync::Scope.for(acs, vector_control: false, zoonoses: true)
      expect(on[:micro_area_ids]).to eq(v13[:micro_area_ids])
      expect(on[:digest]).not_to eq(v13[:digest])
      both = FieldSync::Scope.for(acs, vector_control: true, zoonoses: true)
      expect([ v13[:digest], on[:digest], FieldSync::Scope.for(acs, vector_control: true)[:digest], both[:digest] ].uniq.size).to eq(4)
    end

    it "animal transferido para domicílio fora do escopo → removal animal out_of_scope; deceased → idem; dentro do escopo → reemitido, sem removal" do
      moved, dead, stays, missing = Array.new(4) { animal!(household: household) }
      neighbor = registry_household!(micro_area: area)
      outside = registry_household!
      cursor = last_cursor(all_pages)

      expect(edit(moved, household_id: outside.id)).to be_ok
      expect(edit(dead, status: "deceased")).to be_ok
      expect(edit(stays, household_id: neighbor.id)).to be_ok
      expect(edit(missing, status: "missing")).to be_ok
      expect(FieldSyncTombstone.where(entity_type: "animal").pluck(:entity_id, :micro_area_id, :reason))
        .to contain_exactly([ moved.id, area.id, "out_of_scope" ], [ dead.id, area.id, "out_of_scope" ],
                            [ stays.id, area.id, "out_of_scope" ], [ missing.id, area.id, "out_of_scope" ])

      pages = all_pages(cursor)
      expect(pages.first.fetch("reset")).to be(false)
      expect(removals(pages)).to contain_exactly({ "type" => "animal", "id" => moved.id, "reason" => "out_of_scope" },
                                                 { "type" => "animal", "id" => dead.id, "reason" => "out_of_scope" },
                                                 { "type" => "animal", "id" => missing.id, "reason" => "out_of_scope" })
      expect(refs(pages, "animal")).to eq([ stays.id ])
      expect(body_of(pages, "animal", stays.id)).to include("household_id" => neighbor.id, "version" => 2)

      # O desaparecido que volta (Q31) entra de novo; a lápide antiga sai do fluxo.
      expect(edit(missing, status: "active")).to be_ok
      back = all_pages(last_cursor(pages))
      expect(refs(back, "animal")).to eq([ missing.id ])
      expect(removals(back)).to eq([])
      expect(removals(all_pages).map { _1["id"] }).to contain_exactly(moved.id, dead.id)
    end

    it "o domicílio que muda de microárea leva a lápide dos animais ativos dele" do
      animal = animal!(household: household)
      other = registry_micro_area!(code: "02", team: team)
      cursor = last_cursor(all_pages)
      household.update!(micro_area: other)
      expect(removals(all_pages(cursor))).to include({ "type" => "animal", "id" => animal.id, "reason" => "out_of_scope" })
    end
  end

  it "dose nova reemite o animal com a mesma version e last_rabies_vaccination_on novo; coleira e anulação também" do
    animal = animal!(household: household)
    first = all_pages
    expect(body_of(first, "animal", animal.id)).to include("version" => 1, "last_rabies_vaccination_on" => nil, "collar_due_on" => nil)

    dose = rabies_vaccination!(animal: animal, vaccinated_on: today - 2)
    pages = all_pages(last_cursor(first))
    expect(refs(pages, "animal")).to eq([ animal.id ])
    expect(body_of(pages, "animal", animal.id)).to include("version" => 1, "last_rabies_vaccination_on" => (today - 2).iso8601)

    collar = Zoonoses::PlaceCollar.call(params: { "animal_id" => animal.id, "vector_product_id" => zoonoses_product!(use: "collar").id,
                                                  "placed_on" => today.iso8601 }, by: team_member).payload.fetch(:collar)
    pages = all_pages(last_cursor(pages))
    expect(body_of(pages, "animal", animal.id)).to include("version" => 1, "collar_due_on" => collar.due_on.iso8601)

    expect(Zoonoses::CancelVaccination.call(vaccination: dose, reason: "Registro duplicado da dose.", by: coordinator)).to be_ok
    pages = all_pages(last_cursor(pages))
    expect(body_of(pages, "animal", animal.id)).to include("version" => 1, "last_rabies_vaccination_on" => nil)

    expect(Zoonoses::RemoveCollar.call(collar: collar, reason: "lost", removed_on: nil, by: team_member)).to be_ok
    pages = all_pages(last_cursor(pages))
    expect(body_of(pages, "animal", animal.id)).to include("version" => 1, "collar_due_on" => nil)
  end

  it "nenhum animal traz o número do microchip; o tutor só { patient_id, display_name }, com a trilha da página" do
    tutor = tutor!
    chipped = animal!(household: household, tutor: tutor, microchip: "985112345678903", name: "Bidu", birth_estimate_on: Date.new(2024, 3, 1))
    plain = animal!(household: household, community: true, species: "cat")
    animal!(household: registry_household!) # fora do escopo
    animal!(household: household, status: "deceased")
    animal!(tutor: tutor) # sem domicílio: não vai
    pages = all_pages
    expect(refs(pages, "animal")).to contain_exactly(chipped.id, plain.id)
    expect(pages.to_json).not_to include("985112345678903")
    expect(body_of(pages, "animal", chipped.id)).to eq(
      "id" => chipped.id, "version" => 1, "household_id" => household.id, "species" => "dog", "name" => "Bidu", "sex" => "unknown",
      "size" => nil, "coat" => nil, "breed" => nil, "birth_estimate_on" => "2024-03-01", "status" => "active", "neutered" => false,
      "tutor" => { "patient_id" => tutor.id, "display_name" => tutor.display_name }, "community" => false,
      "last_rabies_vaccination_on" => nil, "collar_due_on" => nil, "has_microchip" => true
    )
    expect(body_of(pages, "animal", plain.id)).to include("tutor" => nil, "community" => true, "has_microchip" => false)
    trail = DomainEvent.where(name: "clinical_record.viewed").select { _1.payload["access"] == "field_sync" }
    expect(trail.flat_map { _1.payload["patient_ids"] }).to include(tutor.id)
  end

  describe "leish_survey" do
    it "traz household_ids do escopo e não city_block_ids; o perfil novo no quarteirão reemite o inquérito" do
      vector_profile!(household, block: block)
      outside = registry_household!.tap { vector_profile!(_1, block: block) }
      survey = leish_survey!(blocks: [ block ])
      leish_survey!(blocks: [ block ], stage: "draft")
      leish_survey!(blocks: [ city_block!(neighborhood: neighborhood, number: "7") ])
      pages = all_pages
      expect(refs(pages, "leish_survey")).to eq([ survey.id ])
      body = body_of(pages, "leish_survey", survey.id)
      expect(body).to eq("id" => survey.id, "version" => 1, "name" => survey.name, "kind" => "sample", "household_ids" => [ household.id ],
                         "starts_on" => survey.starts_on.iso8601, "ends_on" => survey.ends_on.iso8601)
      expect(body["household_ids"]).not_to include(outside.id)

      neighbor = registry_household!(micro_area: area)
      vector_profile!(neighbor, block: block)
      again = all_pages(last_cursor(pages))
      expect(body_of(again, "leish_survey", survey.id).fetch("household_ids")).to match_array([ household.id, neighbor.id ])
    end

    it "inquérito fechado → removal leish_survey out_of_scope (uma lápide por microárea)" do
      vector_profile!(household, block: block)
      vector_profile!(registry_household!(micro_area: area), block: block)
      other_area = registry_household!.tap { vector_profile!(_1, block: block) }.micro_area
      survey = leish_survey!(blocks: [ block ])
      cursor = last_cursor(all_pages)

      expect(Zoonoses::SaveSurvey.transition(survey: survey, params: { "expected_version" => 1 }, by: coordinator, from: "open",
                                             to: "closed")).to be_ok
      expect(FieldSyncTombstone.where(entity_type: "leish_survey").pluck(:micro_area_id)).to contain_exactly(area.id, other_area.id)
      pages = all_pages(cursor)
      expect(removals(pages)).to eq([ { "type" => "leish_survey", "id" => survey.id, "reason" => "out_of_scope" } ])
      expect(of(pages, "leish_survey")).to eq([])
    end

    it "o perfil que sai do quarteirão do inquérito → removal; com outro domicílio do escopo nele, só reemitido" do
      vector_profile!(household, block: block)
      second = registry_household!(micro_area: area).tap { vector_profile!(_1, block: block) }
      survey = leish_survey!(blocks: [ block ])
      far = city_block!(neighborhood: neighborhood, number: "9")
      cursor = last_cursor(all_pages)

      HouseholdVectorProfile.find_by!(household_id: second.id).update!(city_block: far)
      pages = all_pages(cursor)
      expect(removals(pages)).to eq([])
      expect(body_of(pages, "leish_survey", survey.id).fetch("household_ids")).to eq([ household.id ])

      HouseholdVectorProfile.find_by!(household_id: household.id).update!(city_block: far)
      expect(removals(all_pages(last_cursor(pages)))).to eq([ { "type" => "leish_survey", "id" => survey.id, "reason" => "out_of_scope" } ])
    end
  end

  it "gate desligado → nenhum tipo novo nem removal de animal" do
    animal = animal!(household: household)
    vector_profile!(household, block: block)
    leish_survey!(blocks: [ block ])
    cursor = last_cursor(all_pages)
    edit(animal, status: "deceased")
    gate!(false)
    pages = all_pages
    expect(items(pages).map { _1["type"] } & zoonoses_types).to eq([])
    expect(removals(pages)).to eq([])
    expect(fetch(cursor)[:reset]).to be(true)
  end
end
