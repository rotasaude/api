require "rails_helper"

# Módulo 24a (contrato §14 L4, L24): a validação no posto depois do cadastro
# troca os dados digitados pelos validados no PACIENTE; o cadastro só ganha a
# marca identity_changed_at (com o interruptor ligado ou não) — nunca versão
# nem ficha em nome de quem não agiu. A próxima gravação leva a identidade.
RSpec.describe TerritoryRegistry::IdentityRefresh do
  before { registry_city! }

  it "validação no posto depois do cadastro: só a marca, sem versão nem ficha; identity_review_pending até a próxima gravação" do
    typed = Patients::CreateTyped.call(attrs: { "full_name" => "Joao Silva", "birth_date" => "1980-01-01", "sex" => "male",
                                                "no_cpf_reason" => "8", "cns" => valid_cns(5) }, by: verifier!).payload[:patient]
    registration = registry_registration!(patient: typed)
    outbox = LediOutboxEntry.count
    citizen = verified_citizen!(12, full_name: "João da Silva", sex: "male").tap { _1.update!(birth_date: "1980-01-01") }
    Patients::AddCpf.call(patient: registration.patient, cpf: citizen.cpf, by: verifier!)
    registration.reload
    expect([ registration.version, registration.versions.count, LediOutboxEntry.count ]).to eq([ 1, 1, outbox ])
    expect(registration.identity_changed_at).to be_present
    expect(registration).to be_identity_review_pending
    expect(registration.patient.full_name).to eq("João da Silva")
    expect(registration.latest_version.identity).to include("full_name" => "Joao Silva")
  end

  it "sem mudança de identidade, nada; interruptor desligado também só marca" do
    registration = registry_registration!
    expect(described_class.call(registration.patient)).to eq(:none)
    Platform::Features.set!(city: City.find(Current.city.id), key: "territory_registry", enabled: false, maintainer: ledi_maintainer!)
    registration.patient.update!(full_name: "Outro Nome Qualquer")
    expect(described_class.call(registration.patient)).to eq(:marked)
    expect(registration.reload.version).to eq(1)
    expect(registration.identity_changed_at).to be_present
  end

  it "só o cadastro ativo; mudança fora da identidade (raça/cor) não marca" do
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
    expect(registration.reload.identity_changed_at).to be_nil
    citizen.update!(full_name: "Maria Aparecida Souza")
    Patients::Resolve.refresh!(patient.reload)
    expect(registration.reload.identity_changed_at).to be_present
    expect(registration.version).to eq(1)
  end
end
