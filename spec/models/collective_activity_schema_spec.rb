require "rails_helper"
require Rails.root.join("db/city_migrate/20261112900001_add_home_visits.rb").to_s
require Rails.root.join("db/city_migrate/20261112900002_add_collective_activities.rb").to_s

# Módulo 24b (ADR 0052): o banco da atividade coletiva. O local é uma unidade ou um
# texto; as avaliações alteradas não passam dos participantes; a atividade só muda
# para "por engano", uma vez; profissionais e participantes só crescem; a re-cifra
# passa antes de tudo; nada de dado pessoal em inspect.
RSpec.describe "Esquema da atividade coletiva (ADR 0052)", type: :model do
  before { home_visit_city!(collective: true) }

  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def accepted(&block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.not_to raise_error
  end

  let!(:team) { registry_team! }
  let!(:agent) { field_agent!(team: team) }

  # Direto nas linhas; `over` sobrescreve qualquer coluna. Local padrão: texto.
  def activity!(validate: true, **over)
    record = CollectiveActivity.new({ client_uuid: SecureRandom.uuid, team: team, health_unit: team.health_unit,
                                      professional: agent.professional, cbo: "322255", recorded_by_user: agent,
                                      held_on: Time.zone.today, shift: 1, activity_type: 1, place_text: "Praça central",
                                      participants_count: 10, altered_count: 0, origin: "dashboard" }.merge(over))
    record.save!(validate: validate)
    record
  end

  def participant!(activity, patient: registry_patient!, **over)
    CollectiveActivityParticipant.create!({ collective_activity: activity, patient: patient }.merge(over))
  end

  it "local é unidade ou texto, nunca os dois nem nenhum" do
    refused(/ck_collective_activities_place/) { activity!(place_text: nil) }
    refused(/ck_collective_activities_place/) { activity!(place_text: "Praça", place_health_unit: team.health_unit) }
    accepted { activity!(place_text: nil, place_health_unit: team.health_unit) }
    accepted { activity!(place_text: "Escola municipal") }
  end

  it "tipo, turno, participantes e origem têm faixa" do
    refused(/ck_collective_activities_values/) { activity!(activity_type: 8, validate: false) }
    refused(/ck_collective_activities_values/) { activity!(activity_type: 0, validate: false) }
    refused(/ck_collective_activities_values/) { activity!(shift: 4) }
    refused(/ck_collective_activities_participants_count/) { activity!(participants_count: 0) }
    refused(/ck_collective_activities_participants_count/) { activity!(participants_count: 1000) }
    refused(/ck_collective_activities_origin/) { activity!(origin: "field_app") }
    refused(/ck_collective_activities_origin/) { activity!(field_device_id: SecureRandom.uuid) }
    accepted { activity!(activity_type: 7, participants_count: 999) }
  end

  it "avaliações alteradas ≤ participantes" do
    refused(/ck_collective_activities_altered_count/) { activity!(participants_count: 3, altered_count: 4) }
    refused(/ck_collective_activities_altered_count/) { activity!(altered_count: -1) }
    accepted { activity!(participants_count: 3, altered_count: 3) }
    accepted { activity!(participants_count: 3, altered_count: 0) }
  end

  it "a atividade só muda para por engano, uma vez, com os três campos juntos" do
    activity = activity!(meeting_topics: [ 1, 2 ])
    refused(/collective_activities/) { activity.update_columns(shift: 2) }
    refused(/collective_activities/) { activity.update_columns(participants_count: 11) }
    refused(/collective_activities/) { activity.update_columns(mistaken_at: Time.current) } # o trigger recusa antes do CHECK
    refused(/collective_activities/) { activity.update_columns(mistaken_at: Time.current, mistaken_by_user_id: agent.id) }
    refused(/collective_activities/) do
      activity.update_columns(mistaken_at: Time.current, mistaken_by_user_id: agent.id, mistaken_reason: "lançada por engano", shift: 2)
    end
    expect(activity.reload).not_to be_mistaken

    activity.update!(mistaken_at: Time.current, mistaken_by_user: agent, mistaken_reason: "lançada por engano")
    expect(activity).to be_mistaken
    expect(CollectiveActivity.valid).not_to include(activity)
    refused(/collective_activities/) { activity.update_columns(mistaken_at: Time.current + 1.minute) }
    refused(/collective_activities/) { activity.update_columns(mistaken_at: nil, mistaken_by_user_id: nil, mistaken_reason: nil) }
    refused(/collective_activities/) { activity.update_columns(mistaken_reason: "outro motivo qualquer") }
  end

  it "marca de engano: os três campos juntos (CHECK, por INSERT direto)" do
    refused(/ck_collective_activities_mistaken/) { activity!(mistaken_at: Time.current, mistaken_by_user: agent) }
    refused(/ck_collective_activities_mistaken/) { activity!(mistaken_by_user: agent, mistaken_reason: "lançada por engano") }
    refused(/ck_collective_activities_mistaken/) { activity!(mistaken_reason: "lançada por engano") }
    accepted { activity!(mistaken_at: Time.current, mistaken_by_user: agent, mistaken_reason: "lançada por engano") }
  end

  it "profissionais e participantes entram na transação da atividade, nunca depois e nunca em atividade por engano" do
    activity = activity!(participants_count: 2)
    accepted { CollectiveActivityProfessional.create!(collective_activity: activity, professional: agent.professional, cbo: "322255") }
    accepted { participant!(activity) }
    # subtransação já liberada continua sendo a mesma transação
    sub = nil
    ApplicationRecord.transaction(requires_new: true) { sub = activity!(participants_count: 2) }
    accepted { participant!(sub) }

    activity.update!(mistaken_at: Time.current, mistaken_by_user: agent, mistaken_reason: "lançada por engano")
    refused(/activity is marked mistaken/) { participant!(activity) }
    refused(/activity is marked mistaken/) do
      CollectiveActivityProfessional.create!(collective_activity: activity, professional: field_agent!(team: team).professional, cbo: "322255")
    end
  end

  # Atividade gravada e commitada por OUTRA conexão (a de um pedido anterior). As
  # FKs da linha-mãe ficam de fora com session_replication_role = replica (só nessa
  # conexão), e a linha é apagada do mesmo jeito no fim.
  it "profissional e participante de uma atividade gravada em transação anterior → recusado" do
    info = ApplicationRecord.connection.raw_connection.conninfo_hash.compact
    other = PG.connect(info.slice(:host, :port, :dbname, :user, :password))
    id = SecureRandom.uuid
    begin
      other.exec("BEGIN")
      other.exec("SET LOCAL session_replication_role = replica")
      other.exec_params("INSERT INTO collective_activities (id, client_uuid, team_id, health_unit_id, professional_id, cbo, " \
                        "recorded_by_user_id, held_on, shift, activity_type, place_text, participants_count, origin, created_at) " \
                        "VALUES ($1, $2, $3, $3, $3, '322255', $3, current_date, 1, 1, 'Praça', 5, 'dashboard', now())",
                        [ id, SecureRandom.uuid, SecureRandom.uuid ])
      other.exec("COMMIT")
      activity = CollectiveActivity.find(id)
      refused(/rows enter only in the transaction that recorded the activity/) { participant!(activity) }
      refused(/rows enter only in the transaction that recorded the activity/) do
        CollectiveActivityProfessional.create!(collective_activity: activity, professional: agent.professional, cbo: "322255")
      end
    ensure
      other.exec("BEGIN")
      other.exec("SET LOCAL session_replication_role = replica")
      other.exec_params("DELETE FROM collective_activities WHERE id = $1", [ id ])
      other.exec("COMMIT")
      other.close
    end
  end

  it "a re-cifra passa pelo guard de entrada (SET LOCAL rota.reencrypting)" do
    body = ApplicationRecord.connection.select_value("SELECT pg_get_functiondef('rota_collective_activity_child_guard'::regproc)")
    expect(body.index("rota.reencrypting")).to be < body.index("FOR SHARE")
  end

  it "nada se apaga: DELETE e TRUNCATE recusados nas três" do
    activity = activity!
    professional = CollectiveActivityProfessional.create!(collective_activity: activity, professional: agent.professional, cbo: "322255")
    participant = participant!(activity)
    refused(/collective_activities/) { activity.delete }
    refused(/collective_activity_professionals/) { professional.delete }
    refused(/collective_activity_participants/) { participant.delete }
    %w[collective_activities collective_activity_professionals collective_activity_participants].each do |table|
      refused(/#{table}/) { CollectiveActivity.connection.execute("TRUNCATE #{table} CASCADE") }
    end
  end

  it "profissionais e participantes são só acréscimo" do
    activity = activity!(participants_count: 2)
    professional = CollectiveActivityProfessional.create!(collective_activity: activity, professional: agent.professional, cbo: "322255")
    participant = participant!(activity, altered_evaluation: true)
    refused(/collective_activity_professionals/) { professional.update_columns(cbo: "515105") }
    refused(/collective_activity_participants/) { participant.update_columns(patient_id: registry_patient!.id) }
    refused(/collective_activity_participants/) { participant.update_columns(collective_activity_id: activity!.id) }
  end

  it "profissional repetido e participante repetido → RecordNotUnique" do
    activity = activity!
    CollectiveActivityProfessional.create!(collective_activity: activity, professional: agent.professional, cbo: "322255")
    expect { CollectiveActivityProfessional.create!(collective_activity: activity, professional: agent.professional, cbo: "322255") }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_collective_activity_professionals_unique/)
    patient = registry_patient!
    participant!(activity, patient: patient)
    expect { participant!(activity, patient: patient) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_collective_activity_participants_unique/)
    expect { activity!(client_uuid: activity.client_uuid) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_collective_activities_client_uuid/)
  end

  it "cifra as listas, o procedimento, o motivo do engano e os dados do participante (voltam como JSON)" do
    activity = activity!(meeting_topics: [ 1, 7 ], target_audience: [ 3 ], health_topics: [ 6 ], health_practices: [ 30 ],
                         procedure_code: "0101050046")
    participant = participant!(activity, altered_evaluation: true, measurements: { "weight_kg" => 70.5, "height_cm" => 170 },
                                         smoking: { "quit" => true, "dropped_out" => false })
    raw = CollectiveActivity.connection.select_one("SELECT meeting_topics, health_practices, procedure_code FROM collective_activities WHERE id = '#{activity.id}'")
    expect(raw["meeting_topics"]).not_to eq("[1,7]")
    expect(raw["procedure_code"]).not_to include("0101050046")
    raw = CollectiveActivityParticipant.connection.select_one("SELECT altered_evaluation, measurements, smoking FROM collective_activity_participants WHERE id = '#{participant.id}'")
    expect(raw.values.join).not_to include("70.5")
    expect(raw["altered_evaluation"]).not_to eq("true")
    loaded = CollectiveActivity.find(activity.id)
    expect([ loaded.meeting_topics, loaded.target_audience, loaded.health_topics, loaded.health_practices, loaded.procedure_code ])
      .to eq([ [ 1, 7 ], [ 3 ], [ 6 ], [ 30 ], "0101050046" ])
    loaded_participant = CollectiveActivityParticipant.find(participant.id)
    expect([ loaded_participant.altered_evaluation, loaded_participant.measurements, loaded_participant.smoking ])
      .to eq([ true, { "weight_kg" => 70.5, "height_cm" => 170 }, { "quit" => true, "dropped_out" => false } ])
    expect(CityEncryption::CITY_KEYED_TARGETS).to include(
      [ CollectiveActivity, :meeting_topics ], [ CollectiveActivity, :target_audience ], [ CollectiveActivity, :health_topics ],
      [ CollectiveActivity, :health_practices ], [ CollectiveActivity, :procedure_code ], [ CollectiveActivity, :mistaken_reason ],
      [ CollectiveActivityParticipant, :altered_evaluation ], [ CollectiveActivityParticipant, :measurements ],
      [ CollectiveActivityParticipant, :smoking ]
    )
  end

  it "re-cifra passa (SET LOCAL rota.reencrypting = 'on') só nas colunas cifradas" do
    activity = activity!(meeting_topics: [ 1 ])
    participant = participant!(activity, altered_evaluation: true)
    activity.update!(mistaken_at: Time.current, mistaken_by_user: agent, mistaken_reason: "lançada por engano")
    refused(/collective_activities/) { activity.update_columns(meeting_topics: "[2]") }
    refused(/collective_activity_participants/) { participant.update_columns(altered_evaluation: "false") }
    accepted do
      CollectiveActivity.connection.execute("SET LOCAL rota.reencrypting = 'on'")
      activity.update_columns(meeting_topics: "[1]", mistaken_reason: "re-cifrado")
      participant.update_columns(altered_evaluation: "true", measurements: nil)
    end
    refused(/collective_activities/) do
      CollectiveActivity.connection.execute("SET LOCAL rota.reencrypting = 'on'")
      activity.update_columns(shift: 3)
    end
    refused(/collective_activity_participants/) do
      CollectiveActivity.connection.execute("SET LOCAL rota.reencrypting = 'on'")
      participant.update_columns(patient_id: registry_patient!.id)
    end
  end

  it "nada de dado pessoal em inspect, to_s, pretty_print e as_json" do
    activity = activity!(meeting_topics: [ 1 ], place_text: "Rua Secreta, 10")
    participant = participant!(activity, measurements: { "weight_kg" => 70 })
    professional = CollectiveActivityProfessional.create!(collective_activity: activity, professional: agent.professional, cbo: "322255")
    expect(activity.inspect).to eq("#<CollectiveActivity id=#{activity.id} state=recorded>")
    expect(participant.inspect).to eq("#<CollectiveActivityParticipant id=#{participant.id}>")
    expect(professional.inspect).to eq("#<CollectiveActivityProfessional id=#{professional.id}>")
    [ activity, participant, professional ].each do |record|
      expect(record.to_s).to eq(record.inspect)
      expect(record.pretty_inspect.strip).to eq(record.inspect)
    end
    expect(activity.as_json).to eq("id" => activity.id, "state" => "recorded")
    expect(participant.as_json).to eq("id" => participant.id)
    expect(professional.as_json.keys).to eq([ "id" ])
  end

  it "a migração é irreversível e espelha o catálogo" do
    expect { AddCollectiveActivities.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    expect([ AddCollectiveActivities::TYPES, AddCollectiveActivities::SHIFTS, AddCollectiveActivities::ORIGINS,
             AddCollectiveActivities::PLACE_TEXT_MAX ])
      .to eq([ CollectiveActivities::Catalog::TYPES, AddHomeVisits::SHIFTS, HomeVisits::Catalog::ORIGINS,
               CollectiveActivities::Catalog::PLACE_TEXT_MAX ])
  end
end
