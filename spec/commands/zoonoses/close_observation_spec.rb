require "rails_helper"

# Módulo 35b, Task 12 (ADR 0054; contrato §5, §7, Q16): o desfecho da
# observação do animal agressor e a ligação do animal. Desfecho do catálogo,
# outcome_on entre exposure_on e hoje, healthy só a partir de ends_on (o 10º
# dia exato vale), euthanized só com a eutanásia ligada pela
# bite_observation_id, nota opcional 10–500 recusada se longa,
# expected_version → observation_changed. O animal liga-se uma vez, em
# qualquer estado, da mesma espécie. bite_observation.closed só com o id.
RSpec.describe Zoonoses::CloseObservation, type: :model do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }

  def close(observation, by: team, **over)
    params = { "outcome" => "healthy", "outcome_on" => observation.ends_on.iso8601,
               "expected_version" => observation.version }.merge(over.transform_keys(&:to_s))
    described_class.call(observation: observation, params: params.reject { |_, value| value == :omit }, by: by)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "sadio no 9º dia → observation_not_finished; no 10º dia exato (outcome_on = ends_on) → ok" do
    observation = bite_observation!(exposure_on: today - 10)
    expect(observation.ends_on).to eq(today)

    expect(refusal(close(observation, outcome_on: (today - 1).iso8601))).to eq([ :observation_not_finished, { path: "outcome_on" } ])
    expect(observation.reload).to have_attributes(state: "open", version: 1)

    result = close(observation, outcome_on: today.iso8601, outcome_note: "  Animal sadio ao fim dos dez dias.  ")
    expect(result).to be_ok
    expect(observation.reload).to have_attributes(state: "closed", outcome: "healthy", outcome_on: today, version: 2,
                                                  outcome_note: "Animal sadio ao fim dos dez dias.", closed_by_user_id: team.id)
    expect(DomainEvent.where(name: "bite_observation.closed").map(&:payload)).to eq([ { "bite_observation_id" => observation.id } ])
  end

  it "died antes de ends_on → ok (só o sadio espera o fim)" do
    observation = bite_observation!(exposure_on: today - 3)
    expect(close(observation, outcome: "died", outcome_on: (today - 1).iso8601)).to be_ok
  end

  it "outcome_on antes da exposição ou depois de hoje → path outcome_on" do
    observation = bite_observation!(exposure_on: today - 3)
    expect(refusal(close(observation, outcome: "died", outcome_on: (today - 4).iso8601)))
      .to eq([ :date_out_of_range, { path: "outcome_on" } ])
    expect(refusal(close(observation, outcome: "died", outcome_on: (today + 1).iso8601)))
      .to eq([ :date_out_of_range, { path: "outcome_on" } ])
    expect(refusal(close(observation, outcome: "died", outcome_on: "2026-02-30"))).to eq([ :invalid_request, { path: "outcome_on" } ])
    expect(refusal(close(observation, outcome: "died", outcome_on: :omit))).to eq([ :invalid_request, { path: "outcome_on" } ])
    expect(close(observation, outcome: "died", outcome_on: (today - 3).iso8601)).to be_ok # o dia da exposição vale
  end

  it "euthanized sem eutanásia ligada → path outcome; com ela → ok" do
    animal = animal!
    observation = bite_observation!(animal: animal, exposure_on: today - 3)
    euthanasia!(animal: animal) # do animal, mas sem a observação
    expect(refusal(close(observation, outcome: "euthanized", outcome_on: today.iso8601))).to eq([ :invalid_request, { path: "outcome" } ])

    other = animal!
    linked = bite_observation!(animal: other, exposure_on: today - 3)
    euthanasia!(animal: other, bite_observation: linked)
    expect(close(linked, outcome: "euthanized", outcome_on: today.iso8601)).to be_ok
    expect(linked.reload).to have_attributes(state: "closed", outcome: "euthanized")
  end

  it "versão velha → observation_changed; fechada → invalid_transition path status" do
    observation = bite_observation!(exposure_on: today - 10)
    expect(refusal(close(observation, expected_version: 2))).to eq([ :observation_changed, {} ])
    expect(close(observation)).to be_ok
    expect(refusal(close(observation.reload))).to eq([ :invalid_transition, { path: "status" } ])
    expect(DomainEvent.where(name: "bite_observation.closed").count).to eq(1)
  end

  it "forma do corpo: outcome fora do catálogo, nota curta ou longa (recusada, nunca cortada), chave estranha, sem versão" do
    observation = bite_observation!(exposure_on: today - 10)
    expect(refusal(close(observation, outcome: "cancelled"))).to eq([ :invalid_request, { path: "outcome" } ])
    expect(refusal(close(observation, outcome_note: "curta"))).to eq([ :invalid_request, { path: "outcome_note" } ])
    expect(refusal(close(observation, outcome_note: "x" * 501))).to eq([ :invalid_request, { path: "outcome_note" } ])
    expect(refusal(close(observation, place: "shelter"))).to eq([ :invalid_request, { path: "place" } ])
    expect(refusal(close(observation, expected_version: :omit))).to eq([ :expected_version_required, { path: "expected_version" } ])
    expect(refusal(close(observation, expected_version: "1"))).to eq([ :invalid_request, { path: "expected_version" } ])
    expect(refusal(close(observation, by: staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))))
      .to eq([ :missing_role, {} ])
    expect(observation.reload).to have_attributes(state: "open", outcome_note: nil, version: 1)
  end

  describe Zoonoses::LinkObservationAnimal do
    def link(observation, animal_id, by: team, version: observation.version)
      described_class.call(observation: observation, params: { "animal_id" => animal_id, "expected_version" => version }, by: by)
    end

    it "liga o animal na observação aberta e na fechada, uma vez" do
      open = bite_observation!
      dog = animal!
      expect(link(open, dog.id)).to be_ok
      expect(open.reload).to have_attributes(animal_id: dog.id, version: 2, state: "open")

      closed = bite_observation!(state: "closed")
      other = animal!
      expect(link(closed, other.id)).to be_ok
      expect(closed.reload).to have_attributes(animal_id: other.id, version: 2, state: "closed", outcome: "healthy")
    end

    it "já ligado a outro animal → observation_changed; o mesmo animal → nada muda" do
      dog = animal!
      observation = bite_observation!(animal: dog)
      expect(refusal(link(observation, animal!.id))).to eq([ :observation_changed, {} ])
      expect(link(observation, dog.id)).to be_ok
      expect(observation.reload).to have_attributes(animal_id: dog.id, version: 1)
    end

    it "espécie diferente ou animal inexistente → path animal_id; versão velha → observation_changed" do
      observation = bite_observation!
      expect(refusal(link(observation, animal!(species: "cat").id))).to eq([ :invalid_request, { path: "animal_id" } ])
      expect(refusal(link(observation, SecureRandom.uuid))).to eq([ :invalid_request, { path: "animal_id" } ])
      expect(refusal(link(observation, "x"))).to eq([ :invalid_request, { path: "animal_id" } ])
      expect(refusal(link(observation, animal!.id, version: 3))).to eq([ :observation_changed, {} ])
      expect(refusal(described_class.call(observation: observation, params: { "animal_id" => animal!.id }, by: team)))
        .to eq([ :expected_version_required, { path: "expected_version" } ])
      expect(refusal(link(observation, animal!.id, by: staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))))
        .to eq([ :missing_role, {} ])
      expect(observation.reload).to have_attributes(animal_id: nil, version: 1)
    end
  end
end
