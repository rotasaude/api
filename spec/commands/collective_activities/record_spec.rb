require "rails_helper"

# Módulo 24b (ADR 0052; contrato §1, §2, §4, §5, §7, §11, §13; Q15, Q32, Q38,
# Q41, Q42, Q49; plano, Task 13): a gravação da atividade coletiva inteira, numa
# escrita só. Idempotente pelo client_uuid; acesso pela Tabela 5
# (CollectiveActivities::Access); regras do §4 (CollectiveActivities::Rules)
# antes de qualquer escrita; unidade do local ativa com CNES; profissionais com
# vínculo ativo em qualquer equipe e CNS válido (CBO do vínculo); participantes
# por patient_id ou registro rápido (HomeVisits::People, savepoint; a recusa de
# um desfaz tudo); altered_count derivado (Q38); a ficha (Task 14) na mesma
# transação; evento só com ids.
RSpec.describe CollectiveActivities::Record, type: :model do
  let!(:city) { home_visit_city!(collective: true) }
  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def body(**over)
    { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "held_on" => today.iso8601, "shift" => 2, "activity_type" => 5,
      "place_text" => "Salão paroquial", "participants_count" => 12, "target_audience" => [ 12 ], "health_topics" => [ 4 ],
      "participants" => [ { "patient_id" => registry_patient!.id } ] }.merge(over.stringify_keys)
  end

  def typed(name = "Benedita Alves Rocha")
    { "full_name" => name, "birth_date" => "1951-03-08", "sex" => "female", "no_cpf_reason" => "3" }
  end

  def record(params = body, by: acs, **opts) = described_class.call(params: params, by: by, **opts)
  def recorded_events = DomainEvent.where(name: "collective_activity.recorded")
  def failure(result) = [ result.reason, result.details[:path] ]
  def counts = [ CollectiveActivity.count, CollectiveActivityParticipant.count, CollectiveActivityProfessional.count, Patient.count ]

  it "grava tipo 5 com participante novo (registro rápido) e profissional de outra equipe" do
    other_team = registry_team!
    nurse = registry_nurse!(team: other_team)
    existing = registry_patient!
    params = body(professionals: [ { "professional_id" => nurse.professional.id } ], health_practices: [ 25 ],
                  participants: [
                    { "patient_id" => existing.id, "altered_evaluation" => true, "measurements" => { "weight_kg" => 81.23456 },
                      "smoking" => { "quit" => true, "dropped_out" => false } },
                    { "new_patient" => typed, "duplicates_reviewed" => false, "altered_evaluation" => false }
                  ])
    result = nil
    before = Patient.pluck(:id)
    expect { result = record(params) }.to change(Patient, :count).by(1)
    expect(result).to be_ok
    expect(result.payload[:replayed]).to be(false)
    activity = result.payload[:activity].reload
    member = HealthTeamMember.active.find_by!(professional: acs.professional, health_team: team)
    expect(activity).to have_attributes(
      client_uuid: params["client_uuid"], team_id: team.id, health_unit_id: team.health_unit_id, professional_id: acs.professional.id,
      cbo: member.cbo_code, recorded_by_user_id: acs.id, held_on: today, shift: 2, activity_type: 5, place_text: "Salão paroquial",
      place_health_unit_id: nil, participants_count: 12, altered_count: 1, meeting_topics: [], target_audience: [ 12 ],
      health_topics: [ 4 ], health_practices: [ 25 ], procedure_code: nil, origin: "dashboard", field_device_id: nil, mistaken_at: nil
    )
    expect(activity.professionals.map { [ _1.professional_id, _1.cbo ] }).to eq([ [ nurse.professional.id, "223505" ] ])
    rows = activity.participants.index_by(&:patient_id)
    expect(rows.fetch(existing.id)).to have_attributes(altered_evaluation: true, measurements: { "weight_kg" => 81.235 },
                                                         smoking: { "quit" => true, "dropped_out" => false })
    created = Patient.where.not(id: before).sole
    expect(created).to have_attributes(full_name: "Benedita Alves Rocha", sex: "female")
    expect(rows.fetch(created.id)).to have_attributes(altered_evaluation: false, measurements: nil, smoking: nil)
    expect(recorded_events.sole.payload).to eq("collective_activity_id" => activity.id, "user_id" => acs.id)
  end

  it "mesmo client_uuid → replay (sem nova gravação nem evento); de outro usuário → client_uuid_conflict" do
    params = body
    first = record(params)
    again = record(params.merge("participants_count" => 30))
    expect(again).to be_ok
    expect(again.payload).to include(replayed: true)
    expect(again.payload[:activity].id).to eq(first.payload[:activity].id)
    expect(again.payload[:activity].participants_count).to eq(12)
    expect(CollectiveActivity.count).to eq(1)
    expect(recorded_events.count).to eq(1)
    expect(failure(record(params, by: field_agent!(team: team)))).to eq([ :client_uuid_conflict, "client_uuid" ])
    expect(failure(record(params.merge("client_uuid" => "x")))).to eq([ :invalid_request, "client_uuid" ])
  end

  it "CBO fora da Tabela 5 → cbo_not_allowed; sem vínculo na equipe → out_of_scope" do
    clerk = field_agent!(cbo: "221205", team: team)
    expect(CollectiveActivities::Catalog::CBOS).not_to include("221205")
    expect(record(body, by: clerk).reason).to eq(:cbo_not_allowed)
    expect(record(body(team_id: registry_team!.id)).reason).to eq(:out_of_scope)
    expect(record(body(team_id: SecureRandom.uuid)).reason).to eq(:out_of_scope)
    expect(CollectiveActivity.count).to eq(0)
  end

  it "participante repetido → duplicate_participant, nada gravado" do
    patient = registry_patient!
    params = body(participants: [ { "patient_id" => patient.id }, { "patient_id" => patient.id } ])
    result = nil
    expect { result = record(params) }.not_to change { counts }
    expect(failure(result)).to eq([ :duplicate_participant, "participants[1]" ])
    expect(result.details).to eq(path: "participants[1]", confirmable: false)
  end

  it "profissional sem CNS → professional_without_cns; sem vínculo ativo → not_found; quem registra na lista → recusado" do
    doctor = registry_nurse!(team: registry_team!)
    doctor.professional.update_column(:cns, "123456789012345")
    expect(Professionals::Cns.valid?(doctor.professional.reload.cns)).to be(false)
    params = body(professionals: [ { "professional_id" => doctor.professional.id } ])
    expect { expect(failure(record(params))).to eq([ :professional_without_cns, "professionals[0].professional_id" ]) }
      .not_to change { counts }

    gone = registry_nurse!(team: registry_team!)
    HealthTeamMember.where(professional: gone.professional).update_all(ended_on: today - 1)
    expect(failure(record(body(professionals: [ { "professional_id" => gone.professional.id } ]))))
      .to eq([ :not_found, "professionals[0].professional_id" ])
    expect(failure(record(body(professionals: [ { "professional_id" => SecureRandom.uuid } ]))))
      .to eq([ :not_found, "professionals[0].professional_id" ])
    expect(failure(record(body(professionals: [ { "professional_id" => acs.professional.id } ]))))
      .to eq([ :invalid_collective_activity, "professionals[0].professional_id" ])
  end

  it "local unidade: ativa com CNES grava o id; sem CNES ou inativa → path place_health_unit_id" do
    unit = team.health_unit
    ok = record(body(place_text: nil, place_health_unit_id: unit.id))
    expect(ok).to be_ok
    expect(ok.payload[:activity].reload).to have_attributes(place_health_unit_id: unit.id, place_text: nil)

    bare = create_unit("UBS sem CNES", cnes: nil)
    expect(failure(record(body(place_text: nil, place_health_unit_id: bare.id))))
      .to eq([ :invalid_collective_activity, "place_health_unit_id" ])
    bare.update!(cnes: format("%07d", SecureRandom.random_number(10**7)), active: false)
    expect(failure(record(body(place_text: nil, place_health_unit_id: bare.id))))
      .to eq([ :invalid_collective_activity, "place_health_unit_id" ])
    expect(failure(record(body(place_text: nil, place_health_unit_id: SecureRandom.uuid))))
      .to eq([ :not_found, "place_health_unit_id" ])
    expect(CollectiveActivity.count).to eq(1)
  end

  it "regras do §4 antes de qualquer escrita: corpo recusado não cria o paciente novo" do
    params = body(participants: [ { "new_patient" => typed } ], health_topics: [ 18 ])
    expect { expect(failure(record(params))).to eq([ :invalid_collective_activity, "health_topics[0]" ]) }
      .not_to change { counts }
    expect(failure(record(body(held_on: (today + 1).iso8601)))).to eq([ :activity_date_out_of_range, "held_on" ])
  end

  it "participante provisório da UPA → patient_unidentified com o path do participante (Q41)" do
    provisional = Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "homem idoso")
    params = body(participants: [ { "patient_id" => registry_patient!.id }, { "patient_id" => provisional.id } ])
    expect(failure(record(params))).to eq([ :patient_unidentified, "participants[1].patient_id" ])
    expect(failure(record(body(participants: [ { "patient_id" => SecureRandom.uuid } ]))))
      .to eq([ :not_found, "participants[0].patient_id" ])
    expect(CollectiveActivity.count).to eq(0)
  end

  it "duplicado suspeito no 2º participante desfaz o 1º paciente novo; a trilha dos candidatos fica (Q15)" do
    existing = registry_patient!
    suspect = { "full_name" => existing.full_name, "birth_date" => existing.birth_date, "sex" => "female", "no_cpf_reason" => "3" }
    params = body(participants: [ { "new_patient" => typed }, { "new_patient" => suspect } ])
    result = nil
    expect { result = record(params) }.not_to change { counts }
    expect(failure(result)).to eq([ :duplicate_suspected, "participants[1].new_patient" ])
    expect(result.details[:candidates].map { _1[:patient_id] }).to include(existing.id)
    expect(result.details).not_to have_key(:candidate_ids)
    expect(recorded_events).to be_empty
    viewed = DomainEvent.where(name: "clinical_record.viewed").map(&:payload)
    expect(viewed).to include(include("patient_id" => existing.id, "user_id" => acs.id, "access" => "collective_activities"))

    reviewed = params.merge("participants" => [ { "new_patient" => typed }, { "new_patient" => suspect, "duplicates_reviewed" => true } ])
    expect(record(reviewed)).to be_ok
    expect(CollectiveActivityParticipant.count).to eq(2)
  end

  describe "a mesma pessoa duas vezes (Ruling T13-DUP, Q53, Q54)" do
    def viewed_ids = DomainEvent.where(name: "clinical_record.viewed").map { _1.payload["patient_id"] }

    it "dois new_patient iguais → duplicate_participant confirmable true, sem candidates nem trilha, nada gravado" do
      params = body(participants: [ { "new_patient" => typed }, { "new_patient" => typed } ])
      result = nil
      expect { result = record(params) }.not_to change { counts }
      expect(failure(result)).to eq([ :duplicate_participant, "participants[1]" ])
      expect(result.details).to eq(path: "participants[1]", confirmable: true)
      expect(viewed_ids).to be_empty
    end

    it "duplicates_reviewed no segundo libera a semelhança: dois pacientes novos" do
      params = body(participants: [ { "new_patient" => typed }, { "new_patient" => typed, "duplicates_reviewed" => true } ])
      result = nil
      expect { result = record(params) }.to change(Patient, :count).by(2)
      expect(result).to be_ok
      expect(result.payload[:activity].participants.count).to eq(2)
    end

    it "CPF ou CNS igual nunca é liberado, nem com duplicates_reviewed: confirmable false" do
      cpf = typed.except("no_cpf_reason").merge("cpf" => valid_cpf(registry_seq!))
      same_cpf = { "new_patient" => cpf.merge("full_name" => "Outra Pessoa"), "duplicates_reviewed" => true }
      params = body(participants: [ { "new_patient" => cpf }, same_cpf ])
      result = nil
      expect { result = record(params) }.not_to change { counts }
      expect(result.details).to eq(path: "participants[1]", confirmable: false)

      cns = typed.merge("cns" => valid_cns(registry_seq!))
      params = body(participants: [ { "new_patient" => cns }, { "new_patient" => cns, "duplicates_reviewed" => true } ])
      expect(record(params).details).to eq(path: "participants[1]", confirmable: false)
    end

    # Defesa do Record, abaixo do Rules (o envio do app cita pessoas que o
    # Rules não vê, Task 20): o Patients::Duplicates de um participante vê o
    # paciente que outro acabou de criar dentro da transação.
    context "com o Rules sem a checagem (só a defesa do Record)" do
      before { allow(CollectiveActivities::Rules).to receive(:check).and_return([]) }

      it "candidato criado nesta escrita, só semelhança → confirmable true; a trilha sem o id desfeito; a marca libera" do
        created = []
        allow(Patients::CreateTyped).to receive(:call).and_wrap_original do |original, **args|
          original.call(**args).tap { |result| created << result.payload[:patient].id if result.ok? }
        end
        params = body(participants: [ { "new_patient" => typed }, { "new_patient" => typed.merge("mother_name" => "Rita Alves") } ])
        result = nil
        expect { result = record(params) }.not_to change { counts }
        expect(failure(result)).to eq([ :duplicate_participant, "participants[1]" ])
        expect(result.details).to eq(path: "participants[1]", confirmable: true)
        expect(created.size).to eq(1)
        expect(Patient.where(id: created)).to be_empty
        expect(viewed_ids & created).to be_empty

        released = body(participants: [ { "new_patient" => typed }, { "new_patient" => typed, "duplicates_reviewed" => true } ])
        expect(record(released)).to be_ok
      end

      it "candidato criado nesta escrita com o mesmo CNS → confirmable false; CPF igual (cpf_taken) idem" do
        cns = typed.merge("cns" => valid_cns(registry_seq!))
        result = record(body(participants: [ { "new_patient" => cns }, { "new_patient" => cns } ]))
        expect(result.details).to eq(path: "participants[1]", confirmable: false)
        cns_taken = record(body(participants: [ { "new_patient" => cns }, { "new_patient" => cns, "duplicates_reviewed" => true } ]))
        expect(cns_taken.details).to eq(path: "participants[1]", confirmable: false)

        cpf = typed.except("no_cpf_reason").merge("cpf" => valid_cpf(registry_seq!))
        other = { "new_patient" => cpf.merge("full_name" => "Outra Pessoa"), "duplicates_reviewed" => true }
        cpf_taken = record(body(participants: [ { "new_patient" => cpf }, other ]))
        expect([ cpf_taken.reason, cpf_taken.details ]).to eq([ :duplicate_participant, { path: "participants[1]", confirmable: false } ])
        expect(CollectiveActivity.count).to eq(0)
      end
    end
  end

  it "registro rápido inválido → invalid_patient com o path do participante (Q49), nada gravado" do
    params = body(participants: [ { "new_patient" => typed.merge("birth_date" => "2090-01-01") } ])
    result = nil
    expect { result = record(params) }.not_to change { counts }
    expect(result.reason).to eq(:invalid_patient)
    expect(result.details[:path]).to start_with("participants[0].new_patient.")
  end

  it "reunião sem participantes: listas ausentes gravam vazias, altered_count 0; app de campo grava o aparelho" do
    params = body(activity_type: 1, meeting_topics: [ 6 ], target_audience: nil, health_topics: [ 1 ], participants: nil)
    expect(record(params)).to be_ok
    activity = CollectiveActivity.sole
    expect(activity).to have_attributes(activity_type: 1, meeting_topics: [ 6 ], target_audience: [], health_topics: [ 1 ],
                                        health_practices: [], altered_count: 0)
    expect(activity.participants).to be_empty
    expect { record(body, origin: "field_app") }.to raise_error(ArgumentError)
    expect { record(body, origin: "outro") }.to raise_error(ArgumentError)
  end

  it "gera a ficha 6 na mesma transação pela fonte CollectiveActivity, sem dublê (Task 14); falha da ficha desfaz a gravação" do
    expect(Ledi::FichaSources.for(described_class::SOURCE_TYPE)).to eq(Ledi::CollectiveActivityFicha)
    seen = nil
    allow(Ledi::Enqueue).to receive(:call).and_wrap_original do |original, ficha, **opts|
      id = ficha.source[:id]
      seen = [ CollectiveActivity.exists?(id), CollectiveActivityParticipant.where(collective_activity_id: id).count ]
      original.call(ficha, **opts)
    end
    result = record
    expect(result).to be_ok
    activity = result.payload[:activity]
    expect(seen).to eq([ true, 1 ])
    entry = LediOutboxEntry.find_by!(source_type: "CollectiveActivity", source_id: activity.id)
    expect([ entry.ficha_type, entry.competence ]).to eq([ "atividade_coletiva", today.strftime("%Y%m") ])
    inner = Ledi::Version.deserialize(Ledi::FichaTypes.klass("atividade_coletiva"), Ledi::Transport.read(entry.bytes).dadoSerializado)
    expect([ inner.atividadeTipo, inner.numParticipantes, inner.participantes.size ]).to eq([ 5, 12, 1 ])

    allow(Ledi::Enqueue).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "ficha")
    params = body(professionals: [ { "professional_id" => registry_nurse!(team: registry_team!).professional.id } ])
    expect { expect { record(params) }.to raise_error(ActiveRecord::StatementInvalid) }.not_to change { counts }
    expect(LediOutboxEntry.where(source_type: "CollectiveActivity").count).to eq(1)
    expect(recorded_events.count).to eq(1)
  end

  it "tipo 5 com participante sem CPF e sem CNS: grava e a ficha fica não gerada participant_without_identifier (§11)" do
    result = record(body(participants: [ { "new_patient" => typed } ]))
    expect(result).to be_ok
    activity = result.payload[:activity]
    failure = LediGenerationFailure.find_by!(source_type: "CollectiveActivity", source_id: activity.id)
    expect(failure.reason_codes).to eq(%w[participant_without_identifier])
    expect(LediOutboxEntry.where(source_type: "CollectiveActivity")).to be_empty
  end

  it "o Result de recusa não leva tema, local, nome nem documento" do
    params = body(place_text: "Casa da Benedita, rua 7" * 20, participants: [ { "new_patient" => typed } ])
    result = record(params)
    expect(failure(result)).to eq([ :invalid_collective_activity, "place_text" ])
    expect(result.details.to_s).not_to include("Benedita")
  end
end
