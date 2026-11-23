require "rails_helper"

# Módulo 35b, Task 8 (ADR 0054; contrato §7, invariante; Q30, Q31; Review
# Focus 4): a eutanásia, só da veterinária (403 veterinarian_required), uma
# por animal (409 already_euthanized), imutável. Motivo do catálogo, nota
# 10–1000 obrigatória (recusada, nunca cortada; cifrada), base legal não vazia
# da lista, dia até hoje. Na mesma transação o animal vai a deceased com
# status_on = performed_on e a coleira ativa sai com death; a estada aberta
# segue aberta (fecha só pela saída euthanasia). euthanasia.recorded só com o id.
RSpec.describe Zoonoses::RecordEuthanasia, type: :model do
  let!(:city) { zoonoses_city! }
  let(:vet) { veterinarian! }
  let(:today) { Time.zone.today }
  let(:note) { "Leishmaniose visceral confirmada, sem resposta ao tratamento." }

  def euthanize(animal, by: vet, **over)
    params = { "animal_id" => animal&.id, "performed_on" => today.iso8601, "reason" => "leishmaniasis", "reason_note" => note,
               "legal_basis" => %w[cfmv_1000_2012] }.merge(over.transform_keys(&:to_s))
    described_class.call(params: params.reject { |_, value| value == :omit }, by: by)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "Review Focus 4: coleira, estada e observação abertas → deceased, coleira death, estada aberta; saída euthanasia; segunda → already_euthanized" do
    animal = animal!
    collar = collar!(animal: animal, placed_on: today - 40)
    # A observação nasce sem animal e é ligada pela entrada observation (Q16).
    observation = bite_observation!(animal: nil)
    entered = Zoonoses::EnterShelter.call(params: { "animal_id" => animal.id, "health_unit_id" => uvz_unit!.id, "entry_kind" => "observation",
                                                    "bite_observation_id" => observation.id, "entered_on" => (today - 5).iso8601 },
                                          by: zoonoses_team!)
    expect(entered).to be_ok
    stay = entered.payload.fetch(:stay)
    expect(observation.reload).to have_attributes(animal_id: animal.id, place: "shelter")

    result = euthanize(animal, performed_on: (today - 1).iso8601, legal_basis: %w[cfmv_1000_2012 law_14228_2021],
                               shelter_stay_id: stay.id, bite_observation_id: observation.id)
    expect(result).to be_ok
    euthanasia = result.payload.fetch(:euthanasia)
    expect(euthanasia.reload).to have_attributes(animal_id: animal.id, professional_id: vet.professional.id, performed_on: today - 1,
                                                 reason: "leishmaniasis", reason_note: note, shelter_stay_id: stay.id,
                                                 bite_observation_id: observation.id,
                                                 legal_basis: %w[cfmv_1000_2012 law_14228_2021])
    expect(animal.reload).to have_attributes(status: "deceased", status_on: today - 1, version: 2)
    expect(collar.reload).to have_attributes(removed_on: today - 1, removal_reason: "death")
    expect(stay.reload).to have_attributes(exited_on: nil, exit_kind: nil)
    expect(observation.reload.state).to eq("open")
    expect(DomainEvent.where(name: "euthanasia.recorded").sole.payload).to eq("euthanasia_id" => euthanasia.id)
    expect(DomainEvent.where(name: "collar.removed").sole.payload).to eq("collar_id" => collar.id)
    expect(DomainEvent.where(name: "animal.changed").pluck(:payload)).to eq([ { "animal_id" => animal.id } ])
    raw = Euthanasia.connection.select_value("SELECT reason_note FROM euthanasias WHERE id = #{Euthanasia.connection.quote(euthanasia.id)}")
    expect(raw).not_to include("Leishmaniose")

    closed = Zoonoses::ExitShelter.call(stay: stay, params: { "exit_kind" => "euthanasia", "expected_version" => stay.version },
                                        by: zoonoses_team!)
    expect(closed).to be_ok
    # Sem exited_on: o dia da eutanásia (não antes da entrada).
    expect(stay.reload).to have_attributes(exit_kind: "euthanasia", exited_on: today - 1)

    expect(refusal(euthanize(animal))).to eq([ :already_euthanized, {} ])
    expect(Euthanasia.where(animal_id: animal.id).count).to eq(1)
    expect(DomainEvent.where(name: "euthanasia.recorded").count).to eq(1)
  end

  it "zoonoses_team sem o perfil → veterinarian_required, nada gravado" do
    animal = animal!
    expect(refusal(euthanize(animal, by: zoonoses_team!))).to eq([ :veterinarian_required, {} ])
    expect(refusal(euthanize(animal, by: zoonoses_coordinator!))).to eq([ :veterinarian_required, {} ])
    expect(Euthanasia.where(animal_id: animal.id)).to be_empty
    expect(animal.reload.status).to eq("active")
  end

  it "nota de 9 → path reason_note; base vazia → path legal_basis; e as outras recusas de campo" do
    animal = animal!
    [ "a" * 9, "a" * 1001, nil, 42, " #{'a' * 8} " ].each do |bad|
      expect(refusal(euthanize(animal, reason_note: bad))).to eq([ :invalid_request, { path: "reason_note" } ])
    end
    expect(refusal(euthanize(animal, reason_note: :omit))).to eq([ :invalid_request, { path: "reason_note" } ])
    [ [], nil, "cfmv_1000_2012", %w[cfmv_1000_2012 lei_qualquer], [ 1 ], %w[cfmv_1000_2012 cfmv_1000_2012] ].each do |bad|
      expect(refusal(euthanize(animal, legal_basis: bad))).to eq([ :invalid_request, { path: "legal_basis" } ])
    end
    expect(refusal(euthanize(animal, reason: "boredom"))).to eq([ :invalid_request, { path: "reason" } ])
    expect(refusal(euthanize(animal, performed_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "performed_on" } ])
    expect(refusal(euthanize(animal, performed_on: "hoje"))).to eq([ :invalid_request, { path: "performed_on" } ])
    expect(refusal(euthanize(nil))).to eq([ :invalid_request, { path: "animal_id" } ])
    expect(refusal(euthanize(animal, professional_id: SecureRandom.uuid))).to eq([ :invalid_request, { path: "professional_id" } ])
    expect(refusal(euthanize(animal, shelter_stay_id: shelter_stay!(animal: animal!).id))).to eq([ :invalid_request, { path: "shelter_stay_id" } ])
    expect(refusal(euthanize(animal, bite_observation_id: bite_observation!(animal: animal!).id)))
      .to eq([ :invalid_request, { path: "bite_observation_id" } ])
    expect(Euthanasia.where(animal_id: animal.id)).to be_empty

    # Recusada, nunca cortada: 1000 depois do strip passa inteira.
    long = "#{'b' * 1000}  "
    expect(euthanize(animal, reason_note: long).payload.fetch(:euthanasia).reload.reason_note).to eq("b" * 1000)
  end

  it "os domínios do canil em config/zoonoses/domains.yml seguem os códigos e a ordem do Catalog" do
    domains = YAML.load_file(Rails.root.join("config/zoonoses/domains.yml"))
    { "entry_kinds" => Zoonoses::Catalog::ENTRY_KINDS, "exit_kinds" => Zoonoses::Catalog::EXIT_KINDS,
      "euthanasia_reasons" => Zoonoses::Catalog::EUTHANASIA_REASONS, "legal_bases" => Zoonoses::Catalog::LEGAL_BASES }.each do |key, codes|
      expect(domains.fetch(key).pluck("code")).to eq(codes)
      expect(domains.fetch(key).pluck("label")).to all(be_a(String).and(be_present))
    end
  end

  it "Q31: missing → deceased; deceased ou transferred sem eutanásia → animal_not_active" do
    missing = animal!(status: "missing", status_on: today - 20)
    newer = collar!(animal: missing, placed_on: today)
    expect(euthanize(missing, performed_on: (today - 2).iso8601)).to be_ok
    expect(missing.reload).to have_attributes(status: "deceased", status_on: today - 2)
    # Coleira posta depois do dia da morte (lançamento retroativo): sai no dia em que foi posta.
    expect(newer.reload).to have_attributes(removed_on: today, removal_reason: "death")

    %w[deceased transferred].each do |status|
      expect(refusal(euthanize(animal!(status: status, status_on: today)))).to eq([ :animal_not_active, {} ])
    end
  end
end
