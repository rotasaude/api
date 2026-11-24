require "rails_helper"

# Módulo 35b, Task 5 (ADR 0054; contrato §2, Q20, Q22, Q31): o cadastro e a
# edição do animal. Tutor é paciente existente e só sem community; domicílio
# ativo, opcional (com domicílio, o animal pode ficar sem tutor e sem
# community, Q22); microchip e registro só na criação; situação só na edição,
# pelas transições da Q31, com status_on = hoje; transferred e deceased não se
# editam (409 animal_not_active, antes de gravar); expected_version na
# edição. Eventos só com animal_id.
RSpec.describe Zoonoses::SaveAnimal, type: :model do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:household) { registry_household! }

  def params(**over) = { "species" => "dog", "sex" => "female" }.merge(over.transform_keys(&:to_s))
  def refusal(result) = [ result.reason, result.details ]
  def save(by: team, **opts) = described_class.call(by: by, **opts)
  def edit(animal, **over) = save(animal: animal, params: { "expected_version" => animal.reload.version }.merge(over.transform_keys(&:to_s)))

  it "cadastra com tutor e domicílio; animal.registered só com animal_id" do
    tutor = tutor!
    result = save(params: params(name: "Bidu", size: "medium", coat: "Caramelo", breed: "SRD", household_id: household.id,
                                 tutor_patient_id: tutor.id, microchip: "985112345678903", registry_number: "UVZ-12"))
    expect(result).to be_ok
    animal = result.payload.fetch(:animal)
    expect(animal).to have_attributes(species: "dog", sex: "female", name: "Bidu", size: "medium", coat: "Caramelo", breed: "SRD",
                                      household_id: household.id, tutor_patient_id: tutor.id, community: false, status: "active",
                                      microchip: "985112345678903", registry_number: "UVZ-12", created_by_user_id: team.id, version: 1)
    expect(DomainEvent.where(name: "animal.registered").sole.payload).to eq("animal_id" => animal.id)
  end

  it "tutor e community true → invalid_request path community" do
    expect(refusal(save(params: params(tutor_patient_id: tutor!.id, community: true))))
      .to eq([ :invalid_request, { path: "community" } ])
    expect(Animal.count).to eq(0)
  end

  it "domicílio sem tutor e community false → ok (Q22); sem domicílio e sem tutor também" do
    result = save(params: params(household_id: household.id, community: false))
    expect(result).to be_ok
    expect(result.payload[:animal]).to have_attributes(household_id: household.id, tutor_patient_id: nil, community: false)
    expect(save(params: params(community: true))).to be_ok
    expect(save(params: params)).to be_ok
  end

  it "registry_number na edição → path registry_number; microchip na edição → path microchip; status na criação → path status" do
    animal = animal!
    expect(refusal(edit(animal, registry_number: "X1"))).to eq([ :invalid_request, { path: "registry_number" } ])
    expect(refusal(edit(animal, microchip: "985112345678903"))).to eq([ :invalid_request, { path: "microchip" } ])
    expect(refusal(save(params: params(status: "active")))).to eq([ :invalid_request, { path: "status" } ])
  end

  it "domicílio inativo → path household_id; domicílio inexistente → path household_id; tutor inexistente → path tutor_patient_id" do
    household.update_columns(status: "inactive")
    expect(refusal(save(params: params(household_id: household.id)))).to eq([ :invalid_request, { path: "household_id" } ])
    expect(refusal(save(params: params(household_id: SecureRandom.uuid)))).to eq([ :invalid_request, { path: "household_id" } ])
    expect(refusal(save(params: params(tutor_patient_id: SecureRandom.uuid)))).to eq([ :invalid_request, { path: "tutor_patient_id" } ])
  end

  it "microchip de 14 dígitos → path microchip; repetido → microchip_taken" do
    expect(refusal(save(params: params(microchip: "98511234567890")))).to eq([ :invalid_request, { path: "microchip" } ])
    expect(save(params: params(microchip: "985112345678903"))).to be_ok
    expect(refusal(save(params: params(microchip: "985112345678903")))).to eq([ :microchip_taken, { path: "microchip" } ])
    expect(Animal.count).to eq(1)
  end

  it "registro repetido sem caixa → registry_number_taken" do
    expect(save(params: params(registry_number: "ab12"))).to be_ok
    expect(refusal(save(params: params(registry_number: "AB12")))).to eq([ :registry_number_taken, { path: "registry_number" } ])
  end

  it "campos fora do domínio e texto longo recusados, nunca cortados; chave desconhecida → path da chave" do
    expect(refusal(save(params: params(species: "bird")))).to eq([ :invalid_request, { path: "species" } ])
    expect(refusal(save(params: params(sex: nil)))).to eq([ :invalid_request, { path: "sex" } ])
    expect(refusal(save(params: { "species" => "dog" }))).to eq([ :invalid_request, { path: "sex" } ])
    expect(refusal(save(params: params(name: "x" * 61)))).to eq([ :invalid_request, { path: "name" } ])
    expect(refusal(save(params: params(breed: "")))).to eq([ :invalid_request, { path: "breed" } ])
    expect(refusal(save(params: params(community: "true")))).to eq([ :invalid_request, { path: "community" } ])
    expect(refusal(save(params: params(tutor_name: "Fulana")))).to eq([ :invalid_request, { path: "tutor_name" } ])
    expect(refusal(save(params: params(expected_version: 1)))).to eq([ :invalid_request, { path: "expected_version" } ])
  end

  it "birth_estimate_on 2025-03 vira 2025-03-01; birth_estimate_month do app também; mês futuro → path" do
    expect(save(params: params(birth_estimate_on: "2025-03")).payload[:animal].birth_estimate_on).to eq(Date.new(2025, 3, 1))
    expect(save(params: params(birth_estimate_month: "2024-11")).payload[:animal].birth_estimate_on).to eq(Date.new(2024, 11, 1))
    expect(refusal(save(params: params(birth_estimate_on: "2025-13")))).to eq([ :invalid_request, { path: "birth_estimate_on" } ])
    future = (Time.zone.today >> 2).strftime("%Y-%m")
    expect(refusal(save(params: params(birth_estimate_month: future)))).to eq([ :invalid_request, { path: "birth_estimate_month" } ])
  end

  it "edição: expected_version ausente → expected_version_required; velha → animal_changed; muda e soma version; animal.changed só com animal_id" do
    animal = animal!
    expect(refusal(save(animal: animal, params: { "name" => "Rex" }))).to eq([ :expected_version_required, { path: "expected_version" } ])
    expect(refusal(save(animal: animal, params: { "name" => "Rex", "expected_version" => 7 }))).to eq([ :animal_changed, {} ])
    result = edit(animal, name: "Rex", household_id: household.id)
    expect(result).to be_ok
    expect(animal.reload).to have_attributes(name: "Rex", household_id: household.id, version: 2)
    expect(DomainEvent.where(name: "animal.changed").sole.payload).to eq("animal_id" => animal.id)
    expect(edit(animal, name: "Rex")).to be_ok
    expect(animal.reload.version).to eq(2)
    expect(DomainEvent.where(name: "animal.changed").count).to eq(1)
  end

  it "edição: tutor com community true → path community; tira o tutor e vira comunitário" do
    animal = animal!(tutor: tutor!)
    expect(refusal(edit(animal, community: true))).to eq([ :invalid_request, { path: "community" } ])
    expect(edit(animal, tutor_patient_id: nil, community: true)).to be_ok
    expect(animal.reload).to have_attributes(tutor_patient_id: nil, community: true)
  end

  # Q31: active → missing | transferred | deceased; missing → active | deceased.
  it "situação: active → missing com status_on hoje; missing → active → ok; missing → transferred → invalid_transition" do
    animal = animal!
    expect(edit(animal, status: "missing")).to be_ok
    expect(animal.reload).to have_attributes(status: "missing", status_on: Time.zone.today)
    expect(refusal(edit(animal, status: "transferred"))).to eq([ :invalid_transition, { path: "status" } ])
    expect(edit(animal, status: "active")).to be_ok
    expect(animal.reload).to have_attributes(status: "active", status_on: Time.zone.today)
    expect(refusal(edit(animal, status: "lost"))).to eq([ :invalid_request, { path: "status" } ])
  end

  # Task 17, fix round 1 (coordenador): status_on informado vale, só com uma
  # mudança de status, entre o created_at do animal (dia da cidade) e hoje;
  # fora → date_out_of_range path status_on; sem ele, hoje.
  it "status_on informado com a mudança de status vale; futuro ou antes do cadastro → date_out_of_range; sem status → path status_on" do
    today = Time.zone.today
    animal = animal!(created_at: (today - 10).in_time_zone.change(hour: 10))
    expect(edit(animal, status: "missing", status_on: (today - 3).iso8601)).to be_ok
    expect(animal.reload).to have_attributes(status: "missing", status_on: today - 3)

    expect(refusal(edit(animal, status: "active", status_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "status_on" } ])
    expect(refusal(edit(animal, status: "active", status_on: (today - 11).iso8601))).to eq([ :date_out_of_range, { path: "status_on" } ])
    expect(refusal(edit(animal, status: "active", status_on: "ontem"))).to eq([ :invalid_request, { path: "status_on" } ])
    expect(refusal(edit(animal, status_on: today.iso8601))).to eq([ :invalid_request, { path: "status_on" } ])
    expect(animal.reload).to have_attributes(status: "missing", status_on: today - 3, version: 2)

    expect(edit(animal, status: "active", status_on: (today - 10).iso8601)).to be_ok
    expect(animal.reload).to have_attributes(status: "active", status_on: today - 10)
    # Sem mudança de status, o status_on não se aplica (o app manda o corpo inteiro).
    expect(edit(animal, status: "active", status_on: (today - 1).iso8601, name: "Rex")).to be_ok
    expect(animal.reload).to have_attributes(status_on: today - 10, name: "Rex")
    expect(refusal(save(params: params(status_on: today.iso8601)))).to eq([ :invalid_request, { path: "status_on" } ])
  end

  # Task 8 (fix): no canil, a morte vai pela saída death e a transferência pela
  # saída transferred; o PATCH de situação deixaria a estada sem como fechar.
  it "PATCH status with open stay → invalid_transition path status (deceased, transferred, missing); sem estada, inalterado" do
    sheltered = animal!
    stay = shelter_stay!(animal: sheltered)
    %w[deceased transferred missing].each do |status|
      expect(refusal(edit(sheltered, status: status))).to eq([ :invalid_transition, { path: "status" } ])
    end
    expect(sheltered.reload).to have_attributes(status: "active", version: 1)
    expect(edit(sheltered, name: "Rex")).to be_ok
    expect(edit(sheltered, status: "active", name: "Rex")).to be_ok

    stay.update!(exit_kind: "transferred", exited_on: Time.zone.today, version: 2)
    expect(edit(sheltered, status: "missing")).to be_ok
    expect(sheltered.reload.status).to eq("missing")
    free = animal!
    expect(edit(free, status: "deceased")).to be_ok
    expect(free.reload.status).to eq("deceased")
  end

  it "deceased → active → animal_not_active; nome do transferred → animal_not_active; nada gravado" do
    dead = animal!(status: "deceased", status_on: Time.zone.today - 3)
    expect(refusal(edit(dead, status: "active"))).to eq([ :animal_not_active, {} ])
    moved = animal!(status: "transferred")
    expect(refusal(edit(moved, name: "Rex"))).to eq([ :animal_not_active, {} ])
    expect([ dead.reload.status, moved.reload.name, dead.version, moved.version ]).to eq([ "deceased", nil, 1, 1 ])
  end

  it "origin field: agente na microárea do domicílio → ok; fora dela ou sem domicílio → out_of_scope" do
    agent = endemic_agent!
    mine = ovitrap_household!(agent)
    expect(save(by: agent, origin: "field", params: params(household_id: mine.id))).to be_ok
    expect(refusal(save(by: agent, origin: "field", params: params(household_id: household.id)))).to eq([ :out_of_scope, {} ])
    expect(refusal(save(by: agent, origin: "field", params: params))).to eq([ :out_of_scope, {} ])
  end

  it "dashboard sem team? → missing_role" do
    expect(refusal(save(by: staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"), params: params)))
      .to eq([ :missing_role, {} ])
  end

  it "Result nunca leva tutor nem microchip nos details" do
    tutor = tutor!
    save(params: params(microchip: "985112345678903"))
    taken = save(params: params(microchip: "985112345678903", tutor_patient_id: tutor.id))
    expect(taken.details.to_s).not_to include("985112345678903", tutor.id, ZoonosesHelpers::ZOONOSES_TUTOR_NAME)
  end
end
