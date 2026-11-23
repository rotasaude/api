require "rails_helper"

# Módulo 35b, Task 8 (ADR 0054; contrato §7): a castração, só da veterinária
# (veterinarian_required), uma por animal (a segunda → invalid_transition path
# status), com o professional_id do usuário. Marca animals.neutered, que não
# volta. neutering.recorded só com o id.
RSpec.describe Zoonoses::RecordNeutering, type: :model do
  let!(:city) { zoonoses_city! }
  let(:vet) { veterinarian! }
  let(:today) { Time.zone.today }

  def neuter(animal, by: vet, **over)
    params = { "animal_id" => animal.id, "performed_on" => today.iso8601 }.merge(over.transform_keys(&:to_s))
    described_class.call(params: params.reject { |_, value| value == :omit }, by: by)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "veterinária castra; a segunda → invalid_transition; outro da equipe → veterinarian_required" do
    animal = animal!
    stay = shelter_stay!(animal: animal)
    expect(refusal(neuter(animal, by: zoonoses_team!))).to eq([ :veterinarian_required, {} ])

    result = neuter(animal, shelter_stay_id: stay.id)
    expect(result).to be_ok
    neutering = result.payload.fetch(:neutering)
    expect(neutering).to have_attributes(animal_id: animal.id, professional_id: vet.professional.id, performed_on: today,
                                         shelter_stay_id: stay.id)
    expect(animal.reload).to have_attributes(neutered: true, version: 2)
    expect(DomainEvent.where(name: "neutering.recorded").sole.payload).to eq("neutering_id" => neutering.id)

    expect(refusal(neuter(animal))).to eq([ :invalid_transition, { path: "status" } ])
    expect(Neutering.where(animal_id: animal.id).count).to eq(1)
  end

  it "recusas de campo" do
    animal = animal!
    expect(refusal(neuter(animal, performed_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "performed_on" } ])
    expect(refusal(neuter(animal, shelter_stay_id: shelter_stay!(animal: animal!).id))).to eq([ :invalid_request, { path: "shelter_stay_id" } ])
    expect(refusal(neuter(animal, note: "x"))).to eq([ :invalid_request, { path: "note" } ])
    expect(refusal(neuter(animal!(status: "deceased", status_on: today)))).to eq([ :animal_not_active, {} ])
    expect(refusal(neuter(animal!(neutered: true)))).to eq([ :invalid_transition, { path: "status" } ])
  end
end
