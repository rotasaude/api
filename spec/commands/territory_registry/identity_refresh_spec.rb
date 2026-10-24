require "rails_helper"

# Módulo 24a (contrato §14 L4; plano, Desvio 5): a validação no posto depois
# do cadastro troca os dados digitados pelos validados — nova versão
# identity_refresh em nome de quem gravou a anterior, ficha e a marca
# identity_changed_at; sem o interruptor só marca.
RSpec.describe TerritoryRegistry::IdentityRefresh do
  before { registry_city! }

  it "validação no posto depois do cadastro: dados validados substituem os digitados, nova versão e ficha, o que mudou fica marcado" do
    typed = Patients::CreateTyped.call(attrs: { "full_name" => "Joao Silva", "birth_date" => "1980-01-01", "sex" => "male",
                                                "no_cpf_reason" => "8", "cns" => valid_cns(5) }, by: verifier!).payload[:patient]
    registration = registry_registration!(patient: typed)
    first = registration.latest_version
    citizen = verified_citizen!(12, full_name: "João da Silva", sex: "male").tap { _1.update!(birth_date: "1980-01-01") }
    Patients::AddCpf.call(patient: registration.patient, cpf: citizen.cpf, by: verifier!)
    registration.reload
    expect(registration.version).to eq(2)
    expect(registration.identity_changed_at).to be_present
    latest = registration.latest_version
    expect(latest.origin).to eq("identity_refresh")
    expect(latest.identity).to include("full_name" => "João da Silva", "cpf" => citizen.cpf)
    expect(latest).to have_attributes(saved_by_user_id: first.saved_by_user_id, saved_cbo: first.saved_cbo)
    expect(latest.health_conditions).to eq(first.health_conditions)
    expect(registration.registered_at).to be >= first.created_at
    expect(LediOutboxEntry.where(source_id: latest.id)).to exist
  end

  it "sem mudança de identidade, nada; interruptor desligado, só marca" do
    registration = registry_registration!
    expect(described_class.call(registration.patient)).to eq(:none)
    Platform::Features.set!(city: City.find(Current.city.id), key: "territory_registry", enabled: false, maintainer: ledi_maintainer!)
    registration.patient.update!(full_name: "Outro Nome Qualquer")
    expect(described_class.call(registration.patient)).to eq(:marked)
    expect(registration.reload.version).to eq(1)
    expect(registration.identity_changed_at).to be_present
  end

  it "só o cadastro ativo; mudança fora da identidade (raça/cor) não versiona" do
    registration = registry_registration!
    registration.patient.update!(race_color: "01")
    expect(described_class.call(registration.patient)).to eq(:none)
    TerritoryRegistry::ExitRegistration.call(registration: registration, params: { "reason" => "moved", "on" => Time.zone.today.iso8601 },
                                             by: registry_acs_of(registration.household))
    registration.patient.update!(full_name: "Outro Nome Qualquer")
    expect(described_class.call(registration.patient)).to eq(:none)
    expect(registration.reload.version).to eq(2)
  end

  it "Patients::Resolve.refresh! chama a renovação só quando nome, mãe, nascimento ou sexo mudam" do
    patient, citizen = exam_patient!(13, age: 40, sex: "female")
    registration = registry_registration!(patient: patient)
    Patients::Resolve.refresh!(patient.reload)
    expect(registration.reload.version).to eq(1)
    citizen.update!(full_name: "Maria Aparecida Souza")
    Patients::Resolve.refresh!(patient.reload)
    expect(registration.reload.version).to eq(2)
    expect(registration.latest_version.identity["full_name"]).to eq("Maria Aparecida Souza")
  end
end
