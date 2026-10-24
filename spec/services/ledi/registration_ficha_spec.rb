require "rails_helper"

# Módulo 24a (ADR 0042; plano, Desvios 4, 6 e 7): uma ficha por versão do
# cadastro; a atualização aponta a originadora (a mais antiga do cadastro que
# não foi recusada); reenvio de recusada regera da versão com uuid novo, e a
# originadora muda junto (Review Focus 3); sem CPF nem CNS → "não gerada".
RSpec.describe Ledi::IndividualRegistrationFicha do
  before do
    registry_city!
    stub_pec!
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  def inner(entry, type = "cadastro_individual") =
    Ledi::Version.deserialize(Ledi::FichaTypes.klass(type), Ledi::Transport.read(entry.bytes).dadoSerializado)

  it "enfileira uma ficha por versão; a segunda versão aponta a originadora" do
    registration = registry_registration!
    first = LediOutboxEntry.find_by!(source_type: "IndividualRegistrationVersion", source_id: registration.versions.first.id)
    second_version = registry_new_version!(registration)
    second = LediOutboxEntry.find_by!(source_id: second_version.id)
    expect(inner(first).uuidFichaOriginadora).to eq(first.uuid)
    expect(inner(first).fichaAtualizada).to be(false)
    expect(inner(second).uuidFichaOriginadora).to eq(first.uuid)
    expect(inner(second).fichaAtualizada).to be(true)
    expect(Ledi::Transport.read(first.bytes).tipoDadoSerializado).to eq(2)
    expect(described_class.generate(second_version)).to eq(:exists)
  end

  it "cabeçalho de quem gravou: CNS, CBO do vínculo na equipe, INE, CNES da unidade da equipe, instante da versão" do
    registration = registry_registration!
    version = registration.versions.first
    header = inner(LediOutboxEntry.find_by!(source_id: version.id)).headerTransport
    expect([ header.profissionalCNS, header.cboCodigo_2002, header.ine, header.cnes, header.dataAtendimento ])
      .to eq([ version.saved_by_professional.cns, "515105", version.team.ine, version.team.health_unit.cnes, (version.created_at.to_f * 1000).to_i ])
    id = inner(LediOutboxEntry.find_by!(source_id: version.id)).identificacaoUsuarioCidadao
    expect([ id.microArea, id.stForaArea, id.racaCorCidadao, id.cpfCidadao ]).to eq([ "01", false, 4, registration.patient.cpf ])
  end

  it "reenvio da ficha NOVA recusada: uuid e originadora mudam juntos; a atualização seguinte aponta a nova" do
    registration = registry_registration!
    first = LediOutboxEntry.find_by!(source_id: registration.versions.first.id)
    first.update!(status: "sending")
    first.reject!([ Ledi::ErrorCodes::UNKNOWN.dup ])
    status, fresh = described_class.regenerate(first.reload, by: care_admin!)
    expect(status).to eq(:ok)
    expect(fresh.replaces_outbox_id).to eq(first.id)
    expect(inner(fresh).uuid).to eq(fresh.uuid)
    expect(inner(fresh).uuidFichaOriginadora).to eq(fresh.uuid)
    expect(inner(fresh).fichaAtualizada).to be(false)
    later = LediOutboxEntry.find_by!(source_id: registry_new_version!(registration).id)
    expect(inner(later).uuidFichaOriginadora).to eq(fresh.uuid)
    rewrapped = Ledi::Transport.read(Ledi::Transport.rewrap(fresh.bytes, uuid: "1234567-novo"))
    expect(Ledi::Version.deserialize(Ledi::FichaTypes.klass("cadastro_individual"), rewrapped.dadoSerializado).uuidFichaOriginadora).to eq("1234567-novo")
    # atualização: o rewrap troca o uuid e mantém a originadora (que é outra ficha)
    kept = Ledi::Transport.read(Ledi::Transport.rewrap(later.bytes, uuid: "1234567-outro"))
    kept_inner = Ledi::Version.deserialize(Ledi::FichaTypes.klass("cadastro_individual"), kept.dadoSerializado)
    expect([ kept_inner.uuid, kept_inner.uuidFichaOriginadora ]).to eq([ "1234567-outro", fresh.uuid ])
    expect(Ledi::FichaSources.for("IndividualRegistrationVersion")).to eq(described_class)
  end

  it "ficha failed (a fila desistiu; o PEC nunca recebeu) não é originadora: v2 sai como cadastro novo; v3 aponta a v2" do
    registration = registry_registration!
    first = LediOutboxEntry.find_by!(source_id: registration.versions.first.id)
    first.update!(status: "failed")
    second = LediOutboxEntry.find_by!(source_id: registry_new_version!(registration).id)
    expect([ inner(second).uuidFichaOriginadora, inner(second).fichaAtualizada ]).to eq([ second.uuid, false ])
    third = LediOutboxEntry.find_by!(source_id: registry_new_version!(registration).id)
    expect([ inner(third).uuidFichaOriginadora, inner(third).fichaAtualizada ]).to eq([ second.uuid, true ])
  end

  it "paciente sem CPF e sem CNS: não gerada, patient_without_identifier; nada no outbox" do
    registration = registry_registration!(patient: registry_patient_without_cpf!(cns: nil))
    failure = LediGenerationFailure.find_by!(source_type: "IndividualRegistrationVersion", source_id: registration.versions.first.id)
    expect(failure.reason_codes).to eq(%w[patient_without_identifier])
    expect(LediOutboxEntry.where(source_id: registration.versions.first.id)).to be_empty
  end

  it "paciente sem CPF com CNS: a ficha vai com o CNS, stNaoPossuiCpf e a justificativa" do
    patient = registry_patient_without_cpf!(cns: valid_cns(31))
    registration = registry_registration!(patient: patient)
    id = inner(LediOutboxEntry.find_by!(source_id: registration.versions.first.id)).identificacaoUsuarioCidadao
    expect([ id.cpfCidadao, id.cnsCidadao, id.stNaoPossuiCpf, id.justificativaNaoPossuiCpf ]).to eq([ nil, valid_cns(31), true, 3 ])
  end

  it "CBO fora da Tabela 1 do LEDI (defesa: o Access já recusa): não gerada cbo_not_in_ledi_table; gerar de novo resolve depois" do
    registration = registry_registration!(saved_cbo: "515125")
    version = registration.versions.first
    failure = LediGenerationFailure.find_by!(source_type: "IndividualRegistrationVersion", source_id: version.id)
    expect(failure.reason_codes).to eq(%w[cbo_not_in_ledi_table])
    expect { described_class.retry!(failure, by: care_admin!) }.not_to change(LediOutboxEntry, :count)
    expect(failure.reload.resolved?).to be(false)
    expect(Ledi::FichaSources.for(failure.source_type)).to eq(described_class)
  end

  it "gerar de novo: unidade sem CNES na gravação; com o CNES, a ficha nasce e a falha resolve (uma vez)" do
    household = registry_household!
    unit = household.micro_area.team.health_unit
    cnes = unit.cnes
    unit.update!(cnes: nil)
    registration = registry_registration!(household: household)
    failure = LediGenerationFailure.find_by!(source_type: "IndividualRegistrationVersion", source_id: registration.versions.first.id)
    expect(failure.reason_codes).to eq(%w[unit_without_cnes])
    unit.update!(cnes: cnes)
    expect(described_class.retry!(failure, by: care_admin!).resolved?).to be(true)
    expect(LediOutboxEntry.where(source_id: registration.versions.first.id).count).to eq(1)
    expect { described_class.retry!(failure, by: care_admin!) }.to raise_error(Ledi::ScreeningFicha::AlreadyResolved)
  end

  it "saída por óbito: versão exit leva 135, death_on e o número da DO" do
    registration = registry_registration!
    version = registry_new_version!(registration, origin: "exit", exit_reason: "death", exited_on: Date.new(2026, 10, 21),
                                                  death_on: Date.new(2026, 10, 20), death_certificate: "123456789")
    exit = inner(LediOutboxEntry.find_by!(source_id: version.id)).saidaCidadaoCadastro
    expect([ exit.motivoSaidaCidadao, exit.dataObito, exit.numeroDO ]).to eq([ 135, Time.zone.parse("2026-10-20").to_i * 1000, "123456789" ])
  end

  it "nome com cedilha, apóstrofo tipográfico e hífen: o paciente guarda como digitado; a ficha vai no conjunto oficial" do
    patient = registry_patient!
    patient.update!(full_name: "Maria Gonçalves D’Ávila-Souza")
    registration = registry_registration!(patient: patient)
    id = inner(LediOutboxEntry.find_by!(source_id: registration.versions.first.id)).identificacaoUsuarioCidadao
    expect(id.nomeCidadao).to eq("MARIA GONCALVES D'ÁVILA SOUZA")
    expect(patient.reload.full_name).to eq("Maria Gonçalves D’Ávila-Souza")
    [ id.nomeCidadao, id.nomeMaeCidadao ].compact.each do |name|
      expect(TerritoryRegistry::Dictionary.valid_name?(name, strict: true)).to be(true), name
    end
  end
end

RSpec.describe Ledi::HouseholdRegistrationFicha do
  before do
    registry_city!
    stub_pec!
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  def inner(entry) = Ledi::Version.deserialize(Ledi::FichaTypes.klass("cadastro_domiciliar"), Ledi::Transport.read(entry.bytes).dadoSerializado)

  it "uma ficha por versão (tipo 3): endereço com o IBGE e a UF do perfil, bairro do cadastro de bairros, famílias do retrato" do
    household = registry_household!
    responsible = registry_patient!
    family = Family.create!(household: household, responsible_patient: responsible, income_band: "2", members_count: 2, living_since: "2019-03")
    version = registry_new_household_version!(household)
    entry = LediOutboxEntry.find_by!(source_type: "HouseholdVersion", source_id: version.id)
    expect(Ledi::Transport.read(entry.bytes).tipoDadoSerializado).to eq(3)
    t = inner(entry)
    first = LediOutboxEntry.find_by!(source_type: "HouseholdVersion", source_id: household.versions.first.id)
    expect([ t.uuidFichaOriginadora, t.fichaAtualizada ]).to eq([ first.uuid, true ])
    a = t.enderecoLocalPermanencia
    expect([ a.codigoIbgeMunicipio, a.numeroDneUf, a.bairro, a.microArea ]).to eq([ CityProfile.current.ibge_code, "17", "Centro", "01" ])
    row = t.familias.sole
    expect([ row.cpfResponsavel, row.numeroCnsResponsavel, row.numeroMembrosFamilia, row.rendaFamiliar ]).to eq([ responsible.cpf, nil, 2, 2 ])
    expect(family.reload.responsible_patient_id).to eq(responsible.id)
    expect(Ledi::FichaSources.for("HouseholdVersion")).to eq(described_class)
  end

  it "responsável sem CPF e sem CNS: não gerada, responsible_without_identifier" do
    household = registry_household!
    Family.create!(household: household, responsible_patient: registry_patient_without_cpf!(cns: nil), members_count: 1)
    version = registry_new_household_version!(household)
    failure = LediGenerationFailure.find_by!(source_type: "HouseholdVersion", source_id: version.id)
    expect(failure.reason_codes).to eq(%w[responsible_without_identifier])
    expect(LediOutboxEntry.where(source_id: version.id)).to be_empty
  end

  it "CBO fora da Tabela 2 (domiciliar): cbo_not_in_ledi_table" do
    household = registry_household!(saved_cbo: "515124")
    failure = LediGenerationFailure.find_by!(source_type: "HouseholdVersion", source_id: household.versions.first.id)
    expect(failure.reason_codes).to eq(%w[cbo_not_in_ledi_table])
  end
end
