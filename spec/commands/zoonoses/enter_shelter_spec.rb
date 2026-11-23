require "rails_helper"

# Módulo 35b, Task 8 (ADR 0054; contrato §7, Q16, Q31): a entrada no canil ou
# gatil, por team?, numa unidade environmental_surveillance ativa. O animal sem
# cadastro nasce na mesma transação, sem tutor nem domicílio; uma estada
# aberta por animal (409 stay_already_open); a entrada observation exige a
# observação open e marca nela place shelter (Q16); o animal missing volta a
# active (Q31). shelter_stay.opened só com o id.
RSpec.describe Zoonoses::EnterShelter, type: :model do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:unit) { uvz_unit! }
  let(:today) { Time.zone.today }

  def enter(by: team, **over)
    params = { "health_unit_id" => unit.id, "entry_kind" => "collection" }.merge(over.transform_keys(&:to_s))
    described_class.call(params: params.reject { |_, value| value == :omit }, by: by)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "animal novo nasce sem tutor nem domicílio, na mesma transação da estada" do
    result = enter(animal_id: :omit, new_animal: { "species" => "cat", "sex" => "female", "name" => "Mimi" })
    expect(result).to be_ok
    stay = result.payload.fetch(:stay)
    animal = result.payload.fetch(:animal)
    expect(animal.reload).to have_attributes(species: "cat", name: "Mimi", tutor_patient_id: nil, household_id: nil, status: "active",
                                             created_by_user_id: team.id)
    expect(stay.reload).to have_attributes(animal_id: animal.id, health_unit_id: unit.id, entry_kind: "collection", entered_on: today,
                                           exit_kind: nil, version: 1)
    expect(DomainEvent.where(name: "shelter_stay.opened").sole.payload).to eq("shelter_stay_id" => stay.id)
    expect(DomainEvent.where(name: "animal.registered").sole.payload).to eq("animal_id" => animal.id)

    %w[tutor_patient_id household_id].each do |key|
      expect(refusal(enter(new_animal: { "species" => "dog", "sex" => "male", key => tutor!.id })))
        .to eq([ :invalid_request, { path: "new_animal.#{key}" } ])
    end
    expect(refusal(enter(new_animal: { "species" => "lizard", "sex" => "male" }))).to eq([ :invalid_request, { path: "new_animal.species" } ])
    expect(refusal(enter(new_animal: "dog"))).to eq([ :invalid_request, { path: "new_animal" } ])
    expect(refusal(enter(new_animal: { "species" => "dog", "sex" => "male" }, animal_id: animal!.id)))
      .to eq([ :invalid_request, { path: "new_animal" } ])
    # Recusa depois do cadastro (observação fechada): o animal novo e o evento voltam junto.
    closed = bite_observation!(state: "closed")
    expect { enter(new_animal: { "species" => "dog", "sex" => "male" }, entry_kind: "observation", bite_observation_id: closed.id) }
      .not_to change(Animal, :count)
    expect(DomainEvent.where(name: "animal.registered").count).to eq(1)
  end

  it "segunda entrada com a estada aberta → stay_already_open" do
    animal = animal!
    expect(enter(animal_id: animal.id)).to be_ok
    expect(refusal(enter(animal_id: animal.id))).to eq([ :stay_already_open, {} ])
    expect(ShelterStay.where(animal_id: animal.id).count).to eq(1)
  end

  it "observation sem observação aberta → path bite_observation_id; com ela → place shelter" do
    animal = animal!
    closed = bite_observation!(animal: animal, state: "closed")
    expect(refusal(enter(animal_id: animal.id, entry_kind: "observation"))).to eq([ :invalid_request, { path: "bite_observation_id" } ])
    expect(refusal(enter(animal_id: animal.id, entry_kind: "observation", bite_observation_id: closed.id)))
      .to eq([ :invalid_request, { path: "bite_observation_id" } ])
    other = bite_observation!(animal: animal!)
    expect(refusal(enter(animal_id: animal.id, entry_kind: "observation", bite_observation_id: other.id)))
      .to eq([ :observation_changed, {} ])
    expect(refusal(enter(animal_id: animal.id, entry_kind: "collection", bite_observation_id: bite_observation!(animal: animal).id)))
      .to eq([ :invalid_request, { path: "bite_observation_id" } ])
    expect(ShelterStay.where(animal_id: animal.id)).to be_empty

    open = BiteObservation.where(animal_id: animal.id, state: "open").sole
    result = enter(animal_id: animal.id, entry_kind: "observation", bite_observation_id: open.id)
    expect(result).to be_ok
    expect(result.payload.fetch(:stay).bite_observation_id).to eq(open.id)
    expect(open.reload).to have_attributes(place: "shelter", version: 2)
  end

  it "observação sem animal é ligada na entrada; duas entradas de animais diferentes com a mesma observação → a segunda 409 observation_changed" do
    unlinked = bite_observation!(animal: nil)
    first = animal!
    expect(enter(animal_id: first.id, entry_kind: "observation", bite_observation_id: unlinked.id)).to be_ok
    expect(unlinked.reload).to have_attributes(animal_id: first.id, place: "shelter", version: 2)

    second = animal!
    expect(refusal(enter(animal_id: second.id, entry_kind: "observation", bite_observation_id: unlinked.id)))
      .to eq([ :observation_changed, {} ])
    expect(ShelterStay.where(animal_id: second.id)).to be_empty

    # Animal novo com observação sem animal: nasce e já fica ligado.
    fresh = bite_observation!(animal: nil)
    result = enter(new_animal: { "species" => "dog", "sex" => "male" }, entry_kind: "observation", bite_observation_id: fresh.id)
    expect(result).to be_ok
    expect(fresh.reload.animal_id).to eq(result.payload.fetch(:animal).id)
  end

  it "animal missing volta a active na entrada; deceased ou transferred → animal_not_active" do
    missing = animal!(status: "missing", status_on: today - 10)
    expect(enter(animal_id: missing.id, entered_on: (today - 2).iso8601)).to be_ok
    expect(missing.reload).to have_attributes(status: "active", status_on: today - 2, version: 2)
    expect(DomainEvent.where(name: "animal.changed").sole.payload).to eq("animal_id" => missing.id)

    %w[deceased transferred].each do |status|
      expect(refusal(enter(animal_id: animal!(status: status, status_on: today).id))).to eq([ :animal_not_active, {} ])
    end
  end

  it "recusas de campo e de papel" do
    animal = animal!
    expect(refusal(enter(by: staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"), animal_id: animal.id)))
      .to eq([ :missing_role, {} ])
    expect(refusal(enter(animal_id: animal.id, health_unit_id: create_unit("UBS #{SecureRandom.hex(2)}").id)))
      .to eq([ :invalid_request, { path: "health_unit_id" } ])
    inactive = create_unit("UVZ inativa #{SecureRandom.hex(2)}", kind: "environmental_surveillance", active: false)
    expect(refusal(enter(animal_id: animal.id, health_unit_id: inactive.id))).to eq([ :invalid_request, { path: "health_unit_id" } ])
    expect(refusal(enter(animal_id: animal.id, entry_kind: "rescue"))).to eq([ :invalid_request, { path: "entry_kind" } ])
    expect(refusal(enter(animal_id: animal.id, entry_kind: :omit))).to eq([ :invalid_request, { path: "entry_kind" } ])
    expect(refusal(enter(animal_id: :omit))).to eq([ :invalid_request, { path: "animal_id" } ])
    expect(refusal(enter(animal_id: SecureRandom.uuid))).to eq([ :invalid_request, { path: "animal_id" } ])
    expect(refusal(enter(animal_id: animal.id, entered_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "entered_on" } ])
    expect(refusal(enter(animal_id: animal.id, entered_on: "ontem"))).to eq([ :invalid_request, { path: "entered_on" } ])
    expect(refusal(enter(animal_id: animal.id, tutor_name: "x"))).to eq([ :invalid_request, { path: "tutor_name" } ])
    expect(enter(animal_id: animal.id, entered_on: (today - 2).iso8601).payload.fetch(:stay).entered_on).to eq(today - 2)
  end
end
