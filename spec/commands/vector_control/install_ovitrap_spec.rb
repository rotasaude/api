require "rails_helper"

# Módulo 35a, Task 9 (ADR 0054; contrato §6, §17; Q7(2), Q7(5), Q7(6),
# Q13(2); A-9): a instalação da ovitrampa pelo agente de endemias, com o
# quarteirão do perfil congelado, o TCLE e o número livre entre as ativas;
# abre a primeira leitura com a semana epidemiológica inteira YYYYWW.
RSpec.describe VectorControl::InstallOvitrap, type: :model do
  let!(:city) { vector_city! }
  let(:agent) { endemic_agent! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "12") }
  let(:household) { ovitrap_household!(agent, block: block) }

  def params(**over)
    { "client_uuid" => SecureRandom.uuid, "household_id" => household.id, "number" => "OV-1", "consent" => true,
      "installed_on" => Time.zone.today.iso8601 }.merge(over.transform_keys(&:to_s))
  end

  def refusal(result) = [ result.reason, result.details ]

  it "instala: quarteirão congelado, primeira leitura com epi_week YYYYWW, ovitrap.installed; replay e client_uuid alheio" do
    body = params(installed_on: "2026-11-10")
    result = described_class.call(params: body, by: agent)
    expect(result).to be_ok
    ovitrap = result.payload[:ovitrap]
    expect(result.payload[:replayed]).to be(false)
    expect(ovitrap).to have_attributes(number: "OV-1", household_id: household.id, city_block_id: block.id, status: "active",
                                       installed_on: Date.new(2026, 11, 10), origin: "dashboard", field_device_id: nil,
                                       installed_by_user_id: agent.id, client_uuid: body["client_uuid"], version: 1)
    expect(ovitrap.consent_at).to be_present
    reading = ovitrap.readings.sole
    expect(reading).to have_attributes(installed_on: Date.new(2026, 11, 10), epi_week: 202_645, collected_on: nil)
    expect(DomainEvent.where(name: "ovitrap.installed").sole.payload).to eq("ovitrap_id" => ovitrap.id, "user_id" => agent.id)

    again = described_class.call(params: body, by: agent)
    expect([ again.payload[:ovitrap].id, again.payload[:replayed] ]).to eq([ ovitrap.id, true ])
    other = described_class.call(params: body, by: endemic_agent!)
    expect(refusal(other)).to eq([ :client_uuid_conflict, { path: "client_uuid" } ])
    expect(Ovitrap.count).to eq(1)
  end

  it "sem quarteirão → household_without_block; consent false → consent_required; consent \"sim\" → invalid_request; " \
     "número OV 1 → invalid_request; número de ativa → ovitrap_number_taken" do
    bare = ovitrap_household!(agent, neighborhood: neighborhood)
    expect(refusal(described_class.call(params: params(household_id: bare.id), by: agent)))
      .to eq([ :household_without_block, { path: "household_id" } ])
    HouseholdVectorProfile.create!(household: bare, updated_by_user: endemic_coordinator!)
    expect(refusal(described_class.call(params: params(household_id: bare.id), by: agent)))
      .to eq([ :household_without_block, { path: "household_id" } ])

    expect(refusal(described_class.call(params: params(consent: false), by: agent))).to eq([ :consent_required, { path: "consent" } ])
    expect(refusal(described_class.call(params: params(consent: "sim"), by: agent))).to eq([ :invalid_request, { path: "consent" } ])
    expect(refusal(described_class.call(params: params(number: "OV 1"), by: agent))).to eq([ :invalid_request, { path: "number" } ])
    expect(refusal(described_class.call(params: params(number: "OV-1234567890"), by: agent))).to eq([ :invalid_request, { path: "number" } ])

    expect(described_class.call(params: params(number: "OV-7"), by: agent)).to be_ok
    expect(refusal(described_class.call(params: params(number: "ov-7"), by: agent))).to eq([ :ovitrap_number_taken, { path: "number" } ])
    expect(Ovitrap.count).to eq(1)
    expect(DomainEvent.where(name: "ovitrap.installed").count).to eq(1)
  end

  it "corpo: chave a mais, faltando, data futura; domicílio desconhecido → not_found; fora do escopo e outro papel → 403" do
    expect(refusal(described_class.call(params: params(name: "Maria"), by: agent))).to eq([ :invalid_request, { path: "name" } ])
    expect(refusal(described_class.call(params: params.except("installed_on"), by: agent)))
      .to eq([ :invalid_request, { path: "installed_on" } ])
    expect(refusal(described_class.call(params: params(installed_on: (Time.zone.today + 1).iso8601), by: agent)))
      .to eq([ :invalid_request, { path: "installed_on" } ])
    expect(refusal(described_class.call(params: params(client_uuid: "x"), by: agent))).to eq([ :invalid_request, { path: "client_uuid" } ])
    expect(refusal(described_class.call(params: params(household_id: SecureRandom.uuid), by: agent)))
      .to eq([ :not_found, { path: "household_id" } ])

    expect(described_class.call(params: params, by: endemic_agent!).reason).to eq(:out_of_scope)
    expect(described_class.call(params: params, by: registry_acs_of(household)).reason).to eq(:cbo_not_allowed)
    expect(described_class.call(params: params, by: endemic_coordinator!).reason).to eq(:missing_role)
    expect(Ovitrap.count).to eq(0)
  end
end
