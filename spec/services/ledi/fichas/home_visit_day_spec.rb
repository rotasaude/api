require "rails_helper"

# Módulo 24b (ADR 0052; contrato §10, Q4, Q40–Q44; plano, Task 9 e Desvio 9): a
# ficha LEDI de visita domiciliar (tipo 8) de uma folha do dia. Uma ficha por
# folha, as visitas não retiradas em ordem de occurred_at; cabeçalho do dono da
# folha com o dia às 00h no fuso da cidade (W-10); documento CPF xor CNS; na
# visita à família, o do responsável (patient_id); uuidOrigemCadastroDomiciliar
# da ficha utilizável do domicílio, nunca inventado; "não gerada" com a lista
# fechada do §10; folha só com retiradas → :empty, nada gravado. As folhas e as
# visitas nascem direto nas linhas (Ruling A7: antes do HomeVisits::Record).
RSpec.describe Ledi::HomeVisitDayFicha, type: :model do
  before do
    home_visit_city!
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  let(:team) { registry_team! }
  let(:agent) { field_agent!(team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: agent) }
  let(:today) { Time.zone.today }

  def inner(entry) =
    Ledi::Version.deserialize(Ledi::FichaTypes.klass("visita_domiciliar"), Ledi::Transport.read(entry.bytes).dadoSerializado)

  def entry_of(day) = LediOutboxEntry.find_by!(source_type: "HomeVisitDay", source_id: day.id)
  def failure_of(day) = LediGenerationFailure.find_by!(source_type: "HomeVisitDay", source_id: day.id)
  def close!(day) = day.update!(state: "closed", closed_at: Time.current, closed_by: "job")
  def at(hour, min = 0, on: today) = on.in_time_zone.change(hour: hour, min: min)
  def ms(date) = Date.iso8601(date.to_s).in_time_zone.to_i * 1000
  def household_uuid(household) =
    LediOutboxEntry.where(source_type: "HouseholdVersion", source_id: household.versions.first.id).pick(:uuid)

  def typed_patient!(**attrs)
    base = { "full_name" => "Rui Barbosa Prado", "birth_date" => "1958-04-12", "sex" => "male", "no_cpf_reason" => "3",
             "cns" => valid_cns(registry_seq!) }
    result = Patients::CreateTyped.call(attrs: base.merge(attrs.stringify_keys), by: verifier!)
    raise "paciente recusado: #{result.reason}" if result.failure?

    result.payload[:patient]
  end

  def generated!(day)
    close!(day)
    expect(described_class.generate(day)).to eq(:enqueued)
    entry_of(day)
  end

  it "folha com três visitas (morador com CPF, família com responsável sem CPF, imóvel comercial) → ficha igual ao exemplo de referência" do
    day = home_visit_day!(agent: agent, team: team)
    resident = registry_patient!
    home = registry_household!(micro_area: area)
    responsible = typed_patient!
    other_home = registry_household!(micro_area: area)
    family = registry_family!(other_home, responsible: responsible)
    # Gravadas fora de ordem: a ficha segue occurred_at.
    home_visit!(day: day, micro_area: area, occurred_at: at(19, 15), shift: 3, property_type: "2", reasons: [ 35 ], has_reason: true)
    home_visit!(day: day, micro_area: area, occurred_at: at(9, 30), shift: 1, household: home, subject: "resident",
                patient: resident, reasons: [ 11, 12 ], has_reason: true, shared: true,
                measurements: { "weight_kg" => 72.5, "height_cm" => 165.5, "systolic" => 130, "diastolic" => 85,
                                "temperature_c" => 36.6, "glucose_mg_dl" => 110, "glucose_type" => 0 },
                note: "cachorro bravo no portão")
    home_visit!(day: day, micro_area: area, occurred_at: at(14), shift: 2, household: other_home, family: family,
                subject: "family_responsible", patient: responsible, reasons: [ 29 ], has_reason: true)

    entry = generated!(day)
    expect(Ledi::Transport.read(entry.bytes).tipoDadoSerializado).to eq(8)
    expect([ entry.ficha_type, entry.competence ]).to eq([ "visita_domiciliar", today.strftime("%Y%m") ])

    expected = {
      "uuidFicha" => entry.uuid, "tpCdsOrigem" => 3,
      "headerTransport" => { "profissionalCNS" => agent.professional.cns, "cboCodigo_2002" => "515105",
                             "cnes" => team.health_unit.cnes, "ine" => team.ine, "dataAtendimento" => ms(today),
                             "codigoIbgeMunicipio" => CityProfile.current.ibge_code },
      "visitasDomiciliares" => [
        { "turno" => 1, "cpfCidadao" => resident.cpf, "stCidadaoNaoPossuiCpf" => false, "dtNascimento" => ms(resident.birth_date),
          "sexo" => 1, "statusVisitaCompartilhadaOutroProfissional" => true, "motivosVisita" => [ 11, 12 ], "desfecho" => 1,
          "microArea" => "01", "stForaArea" => false, "tipoDeImovel" => 1, "pesoAcompanhamentoNutricional" => 72.5,
          "alturaAcompanhamentoNutricional" => 165.5, "pressaoSistolica" => 130, "pressaoDiastolica" => 85, "temperatura" => 36.6,
          "tipoGlicemia" => 0, "glicemia" => 110, "uuidOrigemCadastroDomiciliar" => household_uuid(home) },
        { "turno" => 2, "cnsCidadao" => responsible.cns, "stCidadaoNaoPossuiCpf" => true, "justificativaCidadaoNaoPossuiCpf" => 3,
          "dtNascimento" => ms("1958-04-12"), "sexo" => 0, "statusVisitaCompartilhadaOutroProfissional" => false,
          "motivosVisita" => [ 29 ], "desfecho" => 1, "microArea" => "01", "stForaArea" => false, "tipoDeImovel" => 1,
          "uuidOrigemCadastroDomiciliar" => household_uuid(other_home) },
        { "turno" => 3, "statusVisitaCompartilhadaOutroProfissional" => false, "motivosVisita" => [ 35 ], "desfecho" => 1,
          "microArea" => "01", "stForaArea" => false, "tipoDeImovel" => 2 }
      ]
    }
    expect(to_h_for_spec(inner(entry))).to eq(expected)
    expect(household_uuid(home)).to be_present
    expect(described_class.generate(day)).to eq(:exists)
    expect(LediGenerationFailure.where(source_type: "HomeVisitDay")).to be_empty
  end

  it "CPF e CNS nunca juntos: com os dois vai só o CPF" do
    day = home_visit_day!(agent: agent, team: team)
    patient = registry_patient!
    patient.update!(cns: valid_cns(registry_seq!))
    home_visit!(day: day, micro_area: area, subject: "resident", patient: patient, reasons: [ 1 ], has_reason: true)
    child = inner(generated!(day)).visitasDomiciliares.sole
    expect([ child.cpfCidadao, child.cnsCidadao, child.stCidadaoNaoPossuiCpf ]).to eq([ patient.cpf, nil, false ])
  end

  it "fora de área: microArea nulo e stForaArea true; desfecho ausente sem motivo vai sem motivosVisita" do
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, outcome: 3)
    child = inner(generated!(day)).visitasDomiciliares.sole
    expect([ child.microArea, child.stForaArea, child.desfecho, child.motivosVisita ]).to eq([ nil, true, 3, nil ])
    expect([ child.numProntuario, child.latitude, child.longitude, child.ivcf ]).to all(be_nil)
  end

  it "uuidOrigemCadastroDomiciliar presente com ficha do domicílio utilizável e ausente sem ela (recusada)" do
    day = home_visit_day!(agent: agent, team: team)
    with_ficha = registry_household!(micro_area: area)
    without = registry_household!(micro_area: area)
    LediOutboxEntry.where(source_type: "HouseholdVersion", source_id: without.versions.select(:id)).find_each do |entry|
      entry.update!(status: "sending")
      entry.reject!([ Ledi::ErrorCodes::UNKNOWN.dup ])
    end
    home_visit!(day: day, micro_area: area, household: with_ficha, occurred_at: at(8))
    home_visit!(day: day, micro_area: area, household: without, occurred_at: at(9))
    children = inner(generated!(day)).visitasDomiciliares
    expect(children.map(&:uuidOrigemCadastroDomiciliar)).to eq([ household_uuid(with_ficha), nil ])
  end

  it "visita retirada fica fora" do
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, micro_area: area, occurred_at: at(8), outcome: 2)
    gone = home_visit!(day: day, micro_area: area, occurred_at: at(9))
    gone.update!(withdrawn_at: Time.current, withdrawn_by_user: agent, withdrawal_reason: "lançada na folha errada")
    children = inner(generated!(day)).visitasDomiciliares
    expect(children.map(&:desfecho)).to eq([ 2 ])
  end

  describe "não gerada (lista fechada do §10)" do
    it "profissional sem CNS válido → professional_without_cns; nada no outbox" do
      day = home_visit_day!(agent: agent, team: team)
      home_visit!(day: day, micro_area: area)
      agent.professional.update_columns(cns: "123456789012345") # dígito errado
      close!(day)
      expect(described_class.generate(day)).to eq(:failed)
      expect(failure_of(day).reason_codes).to eq(%w[professional_without_cns])
      expect(LediOutboxEntry.where(source_id: day.id)).to be_empty
    end

    it "unidade sem CNES → unit_without_cnes; gerar de novo resolve com o CNES" do
      day = home_visit_day!(agent: agent, team: team)
      home_visit!(day: day, micro_area: area)
      cnes = team.health_unit.cnes
      team.health_unit.update!(cnes: nil)
      close!(day)
      expect(described_class.generate(day)).to eq(:failed)
      failure = failure_of(day)
      expect(failure.reason_codes).to eq(%w[unit_without_cnes])
      team.health_unit.update!(cnes: cnes)
      expect(described_class.retry!(failure, by: care_admin!).resolved?).to be(true)
      expect(entry_of(day)).to be_present
    end

    it "paciente sem identificador (provisório da UPA) → patient_without_identifier, com o visit_id em blockers" do
      day = home_visit_day!(agent: agent, team: team)
      provisional = Patient.create!(unidentified: true, no_cpf_reason: "unidentified", unidentified_description: "senhora de azul",
                                    birth_date: "1950-01-01", sex: "female")
      ok = home_visit!(day: day, micro_area: area, occurred_at: at(8))
      visit = home_visit!(day: day, micro_area: area, occurred_at: at(9), subject: "resident", patient: provisional)
      expect(described_class.blockers(day)).to eq([ { code: "patient_without_identifier", visit_id: visit.id } ])
      expect(described_class.blockers(day).map { |row| row[:visit_id] }).not_to include(ok.id)
      close!(day)
      expect(described_class.generate(day)).to eq(:failed)
      expect(failure_of(day).reason_codes).to eq(%w[patient_without_identifier])
    end

    it "pessoa sem nascimento e sem sexo → citizen_without_birth_date e citizen_without_sex (os do 24a, Q4)" do
      day = home_visit_day!(agent: agent, team: team)
      patient = registry_patient!
      patient.update_columns(birth_date: nil, sex: nil)
      home_visit!(day: day, micro_area: area, subject: "resident", patient: patient)
      close!(day)
      expect(described_class.generate(day)).to eq(:failed)
      expect(failure_of(day).reason_codes).to eq(%w[citizen_without_birth_date citizen_without_sex])
    end

    it "prazo do SIAPS vencido → siaps_deadline_passed; gerar de novo segue não gerada" do
      past = today.prev_month(3)
      day = home_visit_day!(agent: agent, team: team, day: past)
      home_visit!(day: day, micro_area: area, occurred_at: at(10, on: past))
      close!(day)
      expect(Ledi::Deadline.on(day.competence)).to be < today
      expect(described_class.generate(day)).to eq(:failed)
      failure = failure_of(day)
      expect(failure.reason_codes).to eq(%w[siaps_deadline_passed])
      expect(described_class.blockers(day)).to eq([ { code: "siaps_deadline_passed", visit_id: nil } ])
      expect(described_class.retry!(failure, by: care_admin!).resolved?).to be(false)
      expect(LediOutboxEntry.where(source_id: day.id)).to be_empty
    end
  end

  it "folha só com retiradas (ou sem visita) → :empty, nada gravado" do
    day = home_visit_day!(agent: agent, team: team)
    gone = home_visit!(day: day, micro_area: area)
    gone.update!(withdrawn_at: Time.current, withdrawn_by_user: agent, withdrawal_reason: "lançada na folha errada")
    agent.professional.update_columns(cns: "123456789012345") # nem a falha nasce
    close!(day)
    expect(described_class.generate(day)).to eq(:empty)
    blank = home_visit_day!(agent: field_agent!(team: team), team: team)
    expect(described_class.generate(blank)).to eq(:empty)
    expect(LediOutboxEntry.where(source_type: "HomeVisitDay")).to be_empty
    expect(LediGenerationFailure.where(source_type: "HomeVisitDay")).to be_empty
  end

  it "generate exige a cidade (vem do CityConnection.with)" do
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, micro_area: area)
    expect { described_class.generate(day, city: nil) }.to raise_error(ArgumentError)
  end

  it "thrift serializa e volta (roundtrip); a ficha cumpre Ledi::Ficha" do
    day = home_visit_day!(agent: agent, team: team)
    home_visit!(day: day, micro_area: area, subject: "resident", patient: registry_patient!, reasons: [ 11 ], has_reason: true,
                measurements: { "weight_kg" => 80.125, "temperature_c" => 37.2 })
    ficha, reasons = described_class.build(day)
    expect(reasons).to eq([])
    expect(Ledi::Ficha.assert!(ficha)).to equal(ficha)
    expect([ ficha.type, ficha.competence, ficha.source ]).to eq([ "visita_domiciliar", today.strftime("%Y%m"),
                                                                  { type: "HomeVisitDay", id: day.id } ])
    thrift = ficha.to_thrift(uuid: "#{ficha.cnes}-#{SecureRandom.uuid}")
    expect { thrift.validate }.not_to raise_error
    back = Ledi::Version.deserialize(Ledi::FichaTypes.klass("visita_domiciliar"), Ledi::Version.serialize(thrift))
    expect(to_h_for_spec(back)).to eq(to_h_for_spec(thrift))
    expect(back.visitasDomiciliares.sole.pesoAcompanhamentoNutricional).to eq(80.125)
  end

  it "inspect, to_s, pretty_print e as_json não mostram CPF: só o tipo e o source_id" do
    day = home_visit_day!(agent: agent, team: team)
    patient = registry_patient!
    home_visit!(day: day, micro_area: area, subject: "resident", patient: patient)
    ficha, = described_class.build(day)
    expect(ficha.inspect).to eq("#<Ledi::Fichas::HomeVisitDay source_id=#{day.id}>")
    expect([ ficha.to_s, ficha.pretty_inspect.strip ]).to all(eq(ficha.inspect))
    expect(ficha.as_json).to eq({ "type" => "visita_domiciliar", "source_id" => day.id })
    expect([ ficha.inspect, ficha.as_json.to_s ].join).not_to include(patient.cpf)
  end

  it "fonte HomeVisitDay registrada; os códigos novos de não gerada na lista fechada (Desvio 9)" do
    expect(Ledi::FichaSources.for("HomeVisitDay")).to eq(described_class)
    expect(LediGenerationFailure::REASONS).to include(*HomeVisits::Catalog::NOT_GENERATED, *CollectiveActivities::Catalog::NOT_GENERATED)
    expect(LediGenerationFailure::REASONS - %w[unit_without_cnes professional_without_team professional_without_cns
                                                citizen_without_birth_date citizen_without_sex unknown_ciap2 regeneration_refused
                                                still_sending patient_without_identifier responsible_without_identifier
                                                cbo_not_in_ledi_table city_profile_incomplete too_many_procedure_codes
                                                quantity_exceeds_location_limit])
      .to eq(%w[siaps_deadline_passed participant_without_identifier participant_without_birth_date participant_without_sex
                participant_professional_without_cns place_without_cnes])
  end
end
