require "rails_helper"

# Módulo 35b, Task 8 (ADR 0054; contrato §7, Q31): a saída do canil, uma vez,
# com expected_version (409 stay_changed). returned exige tutor; adopted exige
# adopter_patient_id, que passa a ser o tutor; death leva o animal a deceased
# (com a coleira ativa removida por death) e exige o animal active ou missing;
# euthanasia exige a eutanásia gravada. shelter_stay.closed só com o id: o
# adotante nunca em evento nem em Result.details.
RSpec.describe Zoonoses::ExitShelter, type: :model do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }

  def exit_stay(stay, by: team, **over)
    params = { "exit_kind" => "transferred", "expected_version" => stay.version }.merge(over.transform_keys(&:to_s))
    described_class.call(stay: stay, params: params.reject { |_, value| value == :omit }, by: by)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "returned sem tutor → path exit_kind; com tutor → ok" do
    stay = shelter_stay!(animal: animal!)
    expect(refusal(exit_stay(stay, exit_kind: "returned"))).to eq([ :invalid_request, { path: "exit_kind" } ])
    expect(stay.reload.exited_on).to be_nil

    tutored = shelter_stay!(animal: animal!(tutor: tutor!))
    result = exit_stay(tutored, exit_kind: "returned")
    expect(result).to be_ok
    expect(tutored.reload).to have_attributes(exit_kind: "returned", exited_on: today, version: 2)
    expect(DomainEvent.where(name: "shelter_stay.closed").sole.payload).to eq("shelter_stay_id" => tutored.id)
  end

  it "adopted grava o tutor (community false); sem adotante → path adopter_patient_id" do
    animal = animal!(community: true)
    stay = shelter_stay!(animal: animal)
    expect(refusal(exit_stay(stay, exit_kind: "adopted"))).to eq([ :invalid_request, { path: "adopter_patient_id" } ])
    expect(refusal(exit_stay(stay, exit_kind: "adopted", adopter_patient_id: SecureRandom.uuid)))
      .to eq([ :invalid_request, { path: "adopter_patient_id" } ])
    adopter = tutor!
    expect(refusal(exit_stay(stay, exit_kind: "transferred", adopter_patient_id: adopter.id)))
      .to eq([ :invalid_request, { path: "adopter_patient_id" } ])

    result = exit_stay(stay, exit_kind: "adopted", adopter_patient_id: adopter.id)
    expect(result).to be_ok
    expect(stay.reload).to have_attributes(exit_kind: "adopted", adopter_patient_id: adopter.id)
    expect(animal.reload).to have_attributes(tutor_patient_id: adopter.id, community: false, version: 2, status: "active")
    expect(DomainEvent.where(name: "animal.changed").sole.payload).to eq("animal_id" => animal.id)
    expect(DomainEvent.where(name: "shelter_stay.closed").sole.payload).to eq("shelter_stay_id" => stay.id)
    expect(DomainEvent.all.map(&:payload).to_json).not_to include(adopter.id)
  end

  it "euthanasia sem eutanásia → path exit_kind; com ela → ok" do
    animal = animal!
    stay = shelter_stay!(animal: animal)
    expect(refusal(exit_stay(stay, exit_kind: "euthanasia"))).to eq([ :invalid_request, { path: "exit_kind" } ])

    euthanasia!(animal: animal, shelter_stay: stay)
    animal.update!(status: "deceased", status_on: today)
    expect(exit_stay(stay, exit_kind: "euthanasia")).to be_ok
    expect(stay.reload).to have_attributes(exit_kind: "euthanasia", exited_on: today)

    # Sem exited_on: max(dia da eutanásia, dia da entrada).
    earlier = animal!
    later_stay = shelter_stay!(animal: earlier, entered_on: today - 4)
    euthanasia!(animal: earlier, performed_on: today - 2)
    expect(exit_stay(later_stay, exit_kind: "euthanasia")).to be_ok
    expect(later_stay.reload.exited_on).to eq(today - 2)
    before_entry = animal!
    entered_stay = shelter_stay!(animal: before_entry, entered_on: today - 1)
    euthanasia!(animal: before_entry, performed_on: today - 6)
    expect(exit_stay(entered_stay, exit_kind: "euthanasia")).to be_ok
    expect(entered_stay.reload.exited_on).to eq(today - 1)
  end

  it "versão velha → stay_changed; sem versão → expected_version_required; saída repetida → invalid_transition" do
    stay = shelter_stay!(animal: animal!)
    expect(refusal(exit_stay(stay, expected_version: 2))).to eq([ :stay_changed, {} ])
    expect(refusal(exit_stay(stay, expected_version: :omit))).to eq([ :expected_version_required, { path: "expected_version" } ])
    expect(exit_stay(stay)).to be_ok
    expect(refusal(exit_stay(stay, expected_version: 1))).to eq([ :stay_changed, {} ])
    expect(refusal(exit_stay(stay.reload))).to eq([ :invalid_transition, { path: "status" } ])
    expect(DomainEvent.where(name: "shelter_stay.closed").count).to eq(1)
  end

  it "death: o animal a deceased no dia da saída e a coleira ativa sai com death; animal final → animal_not_active" do
    animal = animal!(status: "missing", status_on: today - 5)
    collar = collar!(animal: animal, placed_on: today - 30)
    stay = shelter_stay!(animal: animal, entered_on: today - 3)
    expect(exit_stay(stay, exit_kind: "death", exited_on: (today - 1).iso8601)).to be_ok
    expect(animal.reload).to have_attributes(status: "deceased", status_on: today - 1)
    expect(collar.reload).to have_attributes(removed_on: today - 1, removal_reason: "death")
    expect(DomainEvent.where(name: "collar.removed").sole.payload).to eq("collar_id" => collar.id)

    %w[deceased transferred].each do |status|
      final = shelter_stay!(animal: animal!(status: status, status_on: today))
      expect(refusal(exit_stay(final, exit_kind: "death"))).to eq([ :animal_not_active, {} ])
      expect(refusal(exit_stay(final, exit_kind: "adopted", adopter_patient_id: tutor!.id))).to eq([ :animal_not_active, {} ])
    end
  end

  it "recusas de campo e de papel" do
    stay = shelter_stay!(animal: animal!, entered_on: today - 2)
    expect(refusal(exit_stay(stay, by: staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))))
      .to eq([ :missing_role, {} ])
    expect(refusal(exit_stay(stay, exit_kind: "escaped"))).to eq([ :invalid_request, { path: "exit_kind" } ])
    expect(refusal(exit_stay(stay, exit_kind: :omit))).to eq([ :invalid_request, { path: "exit_kind" } ])
    expect(refusal(exit_stay(stay, exited_on: (today - 3).iso8601))).to eq([ :date_out_of_range, { path: "exited_on" } ])
    expect(refusal(exit_stay(stay, exited_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "exited_on" } ])
    expect(refusal(exit_stay(stay, note: "x"))).to eq([ :invalid_request, { path: "note" } ])
    expect(refusal(exit_stay(stay, expected_version: "1"))).to eq([ :invalid_request, { path: "expected_version" } ])
  end
end
