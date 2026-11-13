require "rails_helper"

# Módulo 24b (ADR 0052; contrato §4, §11, §16 Q4, Q38, Q41, Q42; plano, Task 14
# e Desvio 9): a ficha LEDI de atividade coletiva (tipo 6). Uma ficha por
# atividade; cabeçalho de quem registrou com o held_on às 00h no fuso da cidade;
# outraLocalidade xor cnesLocalAtividade, nunca inep; PSE sempre false e sempre
# enviado; tbCdsOrigem 3; profissionais com CNS e CBO do vínculo; participante
# com o CPF, ou sem CPF com o marcador, a justificativa e o CNS. Nos tipos 5 e 6
# o participante sem CPF e sem CNS segura a ficha (participant_without_identifier);
# fora deles entra sem documento (Q42), e numAvaliacoesAlteradas sempre bate com
# a lista (Q38). "Não gerada" com CollectiveActivities::Catalog::NOT_GENERATED.
# As atividades nascem direto nas linhas (como a folha da ficha 8, Ruling A7):
# assim o "não gerada" do local e do profissional, que o Record já recusa,
# fica provado como defesa.
RSpec.describe Ledi::CollectiveActivityFicha, type: :model do
  before do
    home_visit_city!(collective: true)
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let(:today) { Time.zone.today }
  let(:procedure) { "0101050178" }

  def inner(entry) =
    Ledi::Version.deserialize(Ledi::FichaTypes.klass("atividade_coletiva"), Ledi::Transport.read(entry.bytes).dadoSerializado)

  def entry_of(activity) = LediOutboxEntry.find_by!(source_type: "CollectiveActivity", source_id: activity.id)
  def failure_of(activity) = LediGenerationFailure.find_by!(source_type: "CollectiveActivity", source_id: activity.id)
  def ms(date) = Date.iso8601(date.to_s).in_time_zone.to_i * 1000

  def typed_patient!(**attrs)
    base = { "full_name" => "Rui Barbosa Prado", "birth_date" => "1958-04-12", "sex" => "male", "no_cpf_reason" => "3",
             "cns" => valid_cns(registry_seq!) }
    result = Patients::CreateTyped.call(attrs: base.merge(attrs.stringify_keys), by: verifier!)
    raise "paciente recusado: #{result.reason}" if result.failure?

    result.payload[:patient]
  end

  # Sem CPF e sem CNS: só a justificativa do 24a (o modelo exige CPF xor justificativa).
  def undocumented_patient! = typed_patient!(full_name: "Benedita Alves Rocha", birth_date: "1951-03-08", sex: "female", cns: nil)

  # A atividade e os filhos numa transação só (o trigger da T4 só aceita os
  # filhos na transação da atividade), sem o Record e sem gerar a ficha.
  # participants: [{ patient:, altered:, measurements:, smoking: }]; professionals: [[user, cbo]].
  def activity!(type: 4, participants: [], professionals: [], place_unit: nil, place_text: "Salão paroquial", **over)
    ApplicationRecord.transaction do
      member = HealthTeamMember.active.find_by!(professional: acs.professional, health_team: team)
      lists = { meeting_topics: [], target_audience: [ 12 ], health_topics: [ 4 ], health_practices: [] }
      activity = CollectiveActivity.create!(
        { client_uuid: SecureRandom.uuid, team: team, health_unit_id: team.health_unit_id, professional: acs.professional,
          cbo: member.cbo_code, recorded_by_user: acs, held_on: today, shift: 1, activity_type: type,
          place_health_unit_id: place_unit&.id, place_text: (place_text unless place_unit), participants_count: 12,
          altered_count: participants.count { _1[:altered] }, procedure_code: nil, origin: "dashboard", **lists }.merge(over)
      )
      professionals.each do |user, cbo|
        CollectiveActivityProfessional.create!(collective_activity: activity, professional: user.professional, cbo: cbo)
      end
      participants.each do |row|
        CollectiveActivityParticipant.create!(collective_activity: activity, patient: row.fetch(:patient),
                                              altered_evaluation: row[:altered] == true, measurements: row[:measurements],
                                              smoking: row[:smoking])
      end
      activity
    end
  end

  def generated!(activity)
    expect(described_class.generate(activity)).to eq(:enqueued)
    entry_of(activity)
  end

  it "tipo 6 com 3 participantes e 2 profissionais → igual ao exemplo de referência, campo a campo" do
    other_team = registry_team!
    nurse = registry_nurse!(team: other_team)
    tacs = field_agent!(cbo: "322255", team: other_team)
    place = create_unit("Centro comunitário", cnes: format("%07d", SecureRandom.random_number(10**7)))
    with_cpf = registry_patient!
    without_cpf = typed_patient!
    plain = registry_patient!
    activity = activity!(
      type: 6, shift: 2, place_unit: place, participants_count: 20, target_audience: [ 13, 1 ], health_topics: [ 7 ],
      health_practices: [ 25, 30 ], procedure_code: procedure,
      professionals: [ [ nurse, "223505" ], [ tacs, "322255" ] ],
      participants: [
        { patient: with_cpf, altered: true, measurements: { "weight_kg" => 81.235, "height_cm" => 165.5 },
          smoking: { "quit" => true, "dropped_out" => false } },
        { patient: without_cpf, altered: true, smoking: { "dropped_out" => true } },
        { patient: plain, altered: false }
      ]
    )

    entry = generated!(activity)
    expect(Ledi::Transport.read(entry.bytes).tipoDadoSerializado).to eq(6)
    expect([ entry.ficha_type, entry.competence ]).to eq([ "atividade_coletiva", today.strftime("%Y%m") ])

    expected = {
      "uuidFicha" => entry.uuid, "cnesLocalAtividade" => place.cnes, "numParticipantes" => 20, "numAvaliacoesAlteradas" => 2,
      "profissionais" => [ { "cnsProfissional" => nurse.professional.cns, "codigoCbo2002" => "223505" },
                           { "cnsProfissional" => tacs.professional.cns, "codigoCbo2002" => "322255" } ],
      "atividadeTipo" => 6, "publicoAlvo" => [ 13, 1 ], "temasParaSaude" => [ 7 ], "praticasEmSaude" => [ 25, 30 ],
      "participantes" => [
        { "cpfParticipante" => with_cpf.cpf, "stCidadaoNaoPossuiCpf" => false, "dataNascimento" => ms(with_cpf.birth_date),
          "sexo" => 1, "avaliacaoAlterada" => true, "peso" => 81.235, "altura" => 165.5, "cessouHabitoFumar" => true,
          "abandonouGrupo" => false },
        { "cnsParticipante" => without_cpf.cns, "stCidadaoNaoPossuiCpf" => true, "justificativaCidadaoNaoPossuiCpf" => 3,
          "dataNascimento" => ms("1958-04-12"), "sexo" => 0, "avaliacaoAlterada" => true, "abandonouGrupo" => true },
        { "cpfParticipante" => plain.cpf, "stCidadaoNaoPossuiCpf" => false, "dataNascimento" => ms(plain.birth_date),
          "sexo" => 1, "avaliacaoAlterada" => false }
      ],
      "tbCdsOrigem" => 3, "procedimento" => procedure, "turno" => 2,
      "headerTransport" => { "profissionalCNS" => acs.professional.cns, "cboCodigo_2002" => "515105",
                             "cnes" => team.health_unit.cnes, "ine" => team.ine, "dataAtendimento" => ms(today),
                             "codigoIbgeMunicipio" => CityProfile.current.ibge_code },
      "pseEducacao" => false, "pseSaude" => false
    }
    expect(to_h_for_spec(inner(entry))).to eq(expected)
    expect(described_class.generate(activity)).to eq(:exists)
    expect(LediGenerationFailure.where(source_type: "CollectiveActivity")).to be_empty
  end

  it "CPF antes do CNS: com os dois vai só o CPF, com o marcador false e sem justificativa" do
    patient = registry_patient!
    patient.update!(cns: valid_cns(registry_seq!))
    row = inner(generated!(activity!(type: 5, participants: [ { patient: patient } ]))).participantes.sole
    expect([ row.cpfParticipante, row.cnsParticipante, row.stCidadaoNaoPossuiCpf, row.justificativaCidadaoNaoPossuiCpf ])
      .to eq([ patient.cpf, nil, false, nil ])
  end

  it "PSE sempre false e sempre enviado; reunião sem participantes; local em texto, nunca inep" do
    activity = activity!(type: 1, meeting_topics: [ 6 ], target_audience: [], health_topics: [ 1 ], place_text: "Sala da UBS")
    ficha = inner(generated!(activity))
    expect([ ficha.pseEducacao, ficha.pseSaude ]).to eq([ false, false ])
    expect([ ficha.outraLocalidade, ficha.cnesLocalAtividade, ficha.inep ]).to eq([ "Sala da UBS", nil, nil ])
    expect([ ficha.atividadeTipo, ficha.temasParaReuniao, ficha.temasParaSaude, ficha.publicoAlvo ]).to eq([ 1, [ 6 ], [ 1 ], nil ])
    expect([ ficha.participantes, ficha.profissionais, ficha.procedimento, ficha.praticasEmSaude ]).to all(be_nil)
    expect([ ficha.numParticipantes, ficha.numAvaliacoesAlteradas, ficha.tbCdsOrigem ]).to eq([ 12, 0, 3 ])
  end

  it "tipo 4 com participante sem documento: na lista sem CPF nem CNS (Q42), numParticipantes intacto" do
    bare = undocumented_patient!
    expect([ bare.cpf, bare.cns ]).to all(be_blank)
    activity = activity!(type: 4, participants: [ { patient: registry_patient! }, { patient: bare, altered: true } ])
    ficha = inner(generated!(activity))
    expect([ ficha.numParticipantes, ficha.numAvaliacoesAlteradas, ficha.participantes.size ]).to eq([ 12, 1, 2 ])
    expect(to_h_for_spec(ficha.participantes.last)).to eq(
      "stCidadaoNaoPossuiCpf" => true, "justificativaCidadaoNaoPossuiCpf" => 3, "dataNascimento" => ms("1951-03-08"),
      "sexo" => 1, "avaliacaoAlterada" => true
    )
  end

  describe "não gerada (lista fechada do §11, Q4)" do
    it "tipo 5 com participante sem documento → participant_without_identifier; nada no outbox" do
      activity = activity!(type: 5, participants: [ { patient: registry_patient! }, { patient: undocumented_patient! } ])
      expect(described_class.generate(activity)).to eq(:failed)
      expect(failure_of(activity).reason_codes).to eq(%w[participant_without_identifier])
      expect(LediOutboxEntry.where(source_id: activity.id)).to be_empty
    end

    it "local unidade sem CNES → place_without_cnes; gerar de novo resolve com o CNES" do
      place = create_unit("Escola municipal", cnes: nil)
      activity = activity!(place_unit: place)
      expect(described_class.generate(activity)).to eq(:failed)
      failure = failure_of(activity)
      expect(failure.reason_codes).to eq(%w[place_without_cnes])
      place.update!(cnes: format("%07d", SecureRandom.random_number(10**7)))
      expect(described_class.retry!(failure, by: care_admin!).resolved?).to be(true)
      expect(inner(entry_of(activity)).cnesLocalAtividade).to eq(place.cnes)
    end

    it "tipo 5 com participante sem sexo e outro sem nascimento → participant_without_birth_date e participant_without_sex (Q4)" do
      no_sex = registry_patient!
      no_sex.update_columns(sex: nil)
      no_birth = registry_patient!
      no_birth.update_columns(birth_date: nil)
      activity = activity!(type: 5, participants: [ { patient: no_sex }, { patient: no_birth } ])
      expect(described_class.generate(activity)).to eq(:failed)
      expect(failure_of(activity).reason_codes).to eq(%w[participant_without_birth_date participant_without_sex])
    end

    it "profissional participante sem CNS → participant_professional_without_cns" do
      nurse = registry_nurse!(team: registry_team!)
      nurse.professional.update_columns(cns: "123456789012345") # dígito errado
      activity = activity!(professionals: [ [ nurse, "223505" ] ])
      expect(described_class.generate(activity)).to eq(:failed)
      expect(failure_of(activity).reason_codes).to eq(%w[participant_professional_without_cns])
    end

    it "cabeçalho: unidade sem CNES e quem registrou sem CNS, na ordem de NOT_GENERATED" do
      activity = activity!
      team.health_unit.update!(cnes: nil)
      acs.professional.update_columns(cns: "123456789012345")
      expect(described_class.generate(activity.reload)).to eq(:failed)
      expect(failure_of(activity).reason_codes).to eq(%w[unit_without_cnes professional_without_cns])
    end

    it "prazo do SIAPS vencido → siaps_deadline_passed; gerar de novo segue não gerada" do
      activity = activity!(held_on: today.prev_month(3))
      expect(described_class.generate(activity)).to eq(:failed)
      failure = failure_of(activity)
      expect(failure.reason_codes).to eq(%w[siaps_deadline_passed])
      expect(described_class.retry!(failure, by: care_admin!).resolved?).to be(false)
      expect(LediOutboxEntry.where(source_id: activity.id)).to be_empty
    end
  end

  describe "registrada por engano (Q55)" do
    def mistaken!(activity) = activity.update!(mistaken_at: Time.current, mistaken_by_user: acs, mistaken_reason: "Registrada em dobro")

    it "Gerar de novo recusa com ActivityChanged e a falha segue não resolvida" do
      place = create_unit("Escola municipal", cnes: nil)
      activity = activity!(place_unit: place)
      expect(described_class.generate(activity)).to eq(:failed)
      failure = failure_of(activity)
      place.update!(cnes: format("%07d", SecureRandom.random_number(10**7)))
      mistaken!(activity)
      expect { described_class.retry!(failure, by: care_admin!) }.to raise_error(described_class::ActivityChanged)
      expect(failure.reload.resolved?).to be(false)
      expect(LediOutboxEntry.where(source_id: activity.id)).to be_empty
    end

    it "Reenviar recusada → :activity_changed (Ledi::Resend levanta); a ficha já enfileirada segue como estava" do
      activity = activity!
      entry = generated!(activity)
      entry.update_columns(status: "rejected", last_error_codes: [ { "field" => "cnes", "code" => "invalid" } ])
      mistaken!(activity)
      expect(described_class.regenerate(entry, by: care_admin!)).to eq([ :activity_changed, nil ])
      expect { Ledi::Resend.call(entry: entry, by: care_admin!) }.to raise_error(described_class::ActivityChanged)
      expect(LediOutboxEntry.where(source_id: activity.id).pluck(:id, :status)).to eq([ [ entry.id, "rejected" ] ])
    end

    it "a ficha de uma atividade marcada depois de enfileirada não é desfeita" do
      activity = activity!
      entry = generated!(activity)
      mistaken!(activity)
      expect(entry.reload.status).to eq("pending")
    end
  end

  it "generate exige a cidade (vem do CityConnection.with)" do
    expect { described_class.generate(activity!, city: nil) }.to raise_error(ArgumentError)
  end

  it "roundtrip thrift; a ficha cumpre Ledi::Ficha; inspect e as_json sem CPF" do
    patient = registry_patient!
    activity = activity!(type: 6, health_practices: [ 20 ], health_topics: [],
                         participants: [ { patient: patient, measurements: { "weight_kg" => 80.125 } } ])
    ficha, reasons = described_class.build(activity)
    expect(reasons).to eq([])
    expect(Ledi::Ficha.assert!(ficha)).to equal(ficha)
    expect([ ficha.type, ficha.competence, ficha.source ])
      .to eq([ "atividade_coletiva", today.strftime("%Y%m"), { type: "CollectiveActivity", id: activity.id } ])
    thrift = ficha.to_thrift(uuid: "#{ficha.cnes}-#{SecureRandom.uuid}")
    expect { thrift.validate }.not_to raise_error
    back = Ledi::Version.deserialize(Ledi::FichaTypes.klass("atividade_coletiva"), Ledi::Version.serialize(thrift))
    expect(to_h_for_spec(back)).to eq(to_h_for_spec(thrift))
    expect(back.participantes.sole.peso).to eq(80.125)

    expect(ficha.inspect).to eq("#<Ledi::Fichas::CollectiveActivity source_id=#{activity.id}>")
    expect([ ficha.to_s, ficha.pretty_inspect.strip ]).to all(eq(ficha.inspect))
    expect(ficha.as_json).to eq({ "type" => "atividade_coletiva", "source_id" => activity.id })
    expect([ ficha.inspect, ficha.as_json.to_s ].join).not_to include(patient.cpf)
  end

  it "fonte CollectiveActivity registrada (Ledi::FichaSources) e os motivos na lista fechada" do
    expect(Ledi::FichaSources.for("CollectiveActivity")).to eq(described_class)
    expect(described_class::SOURCE_TYPE).to eq(CollectiveActivities::Record::SOURCE_TYPE)
    expect(LediGenerationFailure::REASONS).to include(*CollectiveActivities::Catalog::NOT_GENERATED)
    expect(CollectiveActivities::Catalog::NOT_GENERATED.size).to eq(10)
  end
end
