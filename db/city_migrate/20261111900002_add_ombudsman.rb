# Módulo 33 (ADR 0051): ouvidoria do SUS municipal — o domínio. Respondentes
# (um destino: setor ou unidade), assuntos em dois níveis (semente do contrato
# §7, inserida aqui), configuração (uma linha, id 1, inserida aqui), a
# manifestação (protocolo da sequência ombudsman_protocol_seq, colunas do
# registro imutáveis, anônima só denúncia e sem pessoa), a linha do tempo, os
# encaminhamentos por extrato, os acessos à identidade preservada, os anexos
# (nascem órfãos no upload e somem em cascata com o arquivo órfão; dono = a
# sessão do cidadão, uuid sem FK, ou o usuário), os pedidos de reabertura (um
# pendente; um por ciclo), a pesquisa de satisfação, os avisos ao cidadão, o
# relatório anual e as marcas diárias do job e do teto anônimo. Nome, CPF,
# contato, telefone (o do cidadão excluído, §16 Q57, separado do contato que a
# equipe digita), texto, justificativas, extrato, respostas, motivos e o nome
# do anexo: cifrados com a chave da cidade (os limites de texto ficam nos
# comandos: o cifrado não tem o tamanho do claro). Sequência e triggers em
# db/city_triggers.sql (o dump não representa trigger, sequência nem linha).
# Irreversível.
class AddOmbudsman < ActiveRecord::Migration[8.1]
  # Espelho de Ombudsman::Catalog e das listas dos modelos no dia desta
  # migração (a migração não lê código da aplicação: a lista do banco fica fixa
  # no que foi migrado).
  KINDS = %w[complaint report praise suggestion request].freeze
  MODES = %w[identified preserved anonymous].freeze
  CHANNELS = %w[web in_person phone ouvidorsus].freeze
  STATES = %w[received in_analysis forwarded awaiting_complement answered archived].freeze
  RESOLUTIONS = %w[resolved not_resolved].freeze
  ARCHIVE_REASONS = %w[duplicate no_complement lack_of_clarity lack_of_civility improper loss_of_object forwarded_elsewhere].freeze
  FORWARDING_STATES = %w[pending replied declined cancelled].freeze
  EVENT_KINDS = %w[
    received classified forwarded forwarding_cancelled forwarding_replied forwarding_declined
    forwarding_extended complement_requested complement_received extended interim_response
    final_response archived reopen_requested reopen_rejected reopened resolution_changed
    identity_consent_recorded
  ].freeze
  NOTICE_KINDS = %w[interim_response complement_requested final_response archived reopen_decided].freeze
  MET = %w[yes partly no].freeze
  ACTORS = %w[staff citizen system].freeze
  ACCESS_SCOPES = %w[identity attachment].freeze
  UPLOADERS = %w[citizen staff].freeze
  REOPEN_STATES = %w[pending accepted rejected].freeze
  REPORT_STATES = %w[draft published].freeze
  DAILY_RUN_KINDS = %w[deadlines anonymous_cap].freeze
  SETTING_DAYS = (1..120)
  ANONYMOUS_CAP = (1..1000)
  # Contrato §7: assuntos e subassuntos iniciais (a cidade edita).
  SUBJECT_TREE = [
    [ "Atendimento", [ "Demora", "Conduta de profissional", "Acolhimento" ] ],
    [ "Acesso", [ "Agendamento", "Fila", "Falta de profissional" ] ],
    [ "Medicamentos", [ "Falta", "Dispensação" ] ],
    [ "Exames", [ "Agendamento", "Resultado" ] ],
    [ "Estrutura", [ "Limpeza", "Instalações" ] ],
    [ "Transporte", [] ],
    [ "Vigilância em saúde", [] ],
    [ "Outros", [] ]
  ].freeze
  # As 13 tabelas do módulo (TRUNCATE recusado em todas).
  TABLES = %w[ombudsman_responders ombudsman_subjects ombudsman_settings ombudsman_manifestations ombudsman_events
              ombudsman_forwardings ombudsman_identity_accesses ombudsman_attachments ombudsman_reopen_requests
              ombudsman_satisfaction_responses ombudsman_notices ombudsman_annual_reports ombudsman_daily_runs].freeze

  def up
    create_configuration
    create_manifestations
    create_forwardings_and_accesses
    create_citizen_side
    create_reports
    seed

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_configuration
    create_table :ombudsman_responders, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.references :department, type: :uuid, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, foreign_key: true, index: false
      t.boolean :active, null: false, default: true
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_check_constraint :ombudsman_responders, "num_nonnulls(department_id, health_unit_id) = 1",
                         name: "ck_ombudsman_responders_destination"
    add_index :ombudsman_responders, %i[user_id department_id], unique: true, where: "department_id IS NOT NULL",
                                                                name: "idx_ombudsman_responders_department"
    add_index :ombudsman_responders, %i[user_id health_unit_id], unique: true, where: "health_unit_id IS NOT NULL",
                                                                 name: "idx_ombudsman_responders_health_unit"

    create_table :ombudsman_subjects, id: :uuid do |t|
      t.string :name, limit: 80, null: false
      t.references :parent, type: :uuid, foreign_key: { to_table: :ombudsman_subjects }, index: false
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :ombudsman_subjects, "COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name)", unique: true,
                                                                                                                  name: "idx_ombudsman_subjects_name"

    create_table :ombudsman_settings, id: :smallint do |t|
      t.integer :response_days, null: false, default: 30
      t.integer :extension_days, null: false, default: 30
      t.integer :urgent_days, null: false, default: 15
      t.integer :complement_days, null: false, default: 20
      t.integer :forwarding_days, null: false, default: 20
      t.integer :forwarding_extension_days, null: false, default: 20
      t.integer :warning_days, null: false, default: 5
      t.integer :anonymous_daily_cap, null: false, default: 50
      t.references :updated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :updated_at, null: false
    end
    add_check_constraint :ombudsman_settings, "id = 1", name: "ck_ombudsman_settings_singleton"
    days = %w[response_days extension_days urgent_days complement_days forwarding_days forwarding_extension_days warning_days]
    add_check_constraint :ombudsman_settings,
                         (days.map { |c| "#{c} >= #{SETTING_DAYS.min} AND #{c} <= #{SETTING_DAYS.max}" } +
                          [ "anonymous_daily_cap >= #{ANONYMOUS_CAP.min} AND anonymous_daily_cap <= #{ANONYMOUS_CAP.max}" ]).join(" AND "),
                         name: "ck_ombudsman_settings_ranges"
  end

  def create_manifestations
    create_table :ombudsman_manifestations, id: :uuid do |t|
      t.string :protocol, limit: 20, null: false
      t.string :kind, null: false
      t.string :identification_mode, null: false
      t.string :channel, null: false
      t.string :ouvidorsus_number, limit: 40
      t.references :citizen, type: :uuid, foreign_key: true, index: false
      t.text :manifestant_name
      t.text :manifestant_contact
      t.text :manifestant_cpf
      t.text :manifestant_phone
      t.text :body, null: false
      t.references :subject, type: :uuid, foreign_key: { to_table: :ombudsman_subjects }, index: false
      t.references :referred_health_unit, type: :uuid, foreign_key: { to_table: :health_units }, index: false
      t.references :referred_professional, type: :uuid, foreign_key: { to_table: :professionals }, index: false
      t.boolean :urgent, null: false, default: false
      t.string :state, null: false
      t.datetime :received_at, null: false
      t.date :cycle_started_on, null: false
      t.boolean :extended, null: false, default: false
      t.text :extension_reason
      t.integer :suspended_days, null: false, default: 0
      t.datetime :complement_requested_at
      t.boolean :complement_used, null: false, default: false
      t.string :resolution
      t.string :archive_reason
      t.references :duplicate_of, type: :uuid, foreign_key: { to_table: :ombudsman_manifestations }, index: false
      t.string :external_body_name, limit: 120
      t.datetime :concluded_at
      t.integer :cycle, null: false, default: 1
      t.references :created_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :ombudsman_manifestations, :protocol, unique: true, name: "idx_ombudsman_manifestations_protocol"
    add_index :ombudsman_manifestations, %i[state received_at], name: "idx_ombudsman_manifestations_state"
    add_index :ombudsman_manifestations, :citizen_id, where: "citizen_id IS NOT NULL", name: "idx_ombudsman_manifestations_citizen"
    add_index :ombudsman_manifestations, %i[channel identification_mode received_at], name: "idx_ombudsman_manifestations_anonymous_cap"
    {
      "protocol" => "protocol::text ~ '^[0-9]{4}-[0-9]{6,}$'::text",
      "kind" => in_list("kind", KINDS),
      "identification_mode" => in_list("identification_mode", MODES),
      "channel" => in_list("channel", CHANNELS),
      "state" => in_list("state", STATES),
      "resolution" => "resolution IS NULL OR #{in_list('resolution', RESOLUTIONS)}",
      "archive_reason" => "archive_reason IS NULL OR #{in_list('archive_reason', ARCHIVE_REASONS)}",
      "anonymous" => "identification_mode::text <> 'anonymous'::text OR (kind::text = 'report'::text AND citizen_id IS NULL AND " \
                     "manifestant_name IS NULL AND manifestant_contact IS NULL AND manifestant_cpf IS NULL AND manifestant_phone IS NULL)",
      "ouvidorsus" => "(channel::text = 'ouvidorsus'::text) = (ouvidorsus_number IS NOT NULL)",
      # IS NOT DISTINCT FROM: com archive_reason nulo, `=` daria NULL e o CHECK passaria.
      "duplicate" => "(archive_reason::text IS NOT DISTINCT FROM 'duplicate'::text) = (duplicate_of_id IS NOT NULL)",
      "elsewhere" => "(archive_reason::text IS NOT DISTINCT FROM 'forwarded_elsewhere'::text) = (external_body_name IS NOT NULL)",
      "archived" => "(state::text = 'archived'::text) = (archive_reason IS NOT NULL)",
      "web_creator" => "(channel::text = 'web'::text) = (created_by_user_id IS NULL)",
      "cycle" => "cycle >= 1 AND suspended_days >= 0"
    }.each { |name, expression| add_check_constraint :ombudsman_manifestations, expression, name: "ck_ombudsman_manifestations_#{name}" }

    create_table :ombudsman_events, id: :uuid do |t|
      t.references :ombudsman_manifestation, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.string :actor, null: false
      t.references :actor_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :text
      t.jsonb :data, null: false, default: {}
      t.boolean :visible_to_citizen, null: false, default: false
      t.datetime :created_at, null: false
    end
    add_index :ombudsman_events, %i[ombudsman_manifestation_id created_at id], name: "idx_ombudsman_events_manifestation"
    add_check_constraint :ombudsman_events, in_list("kind", EVENT_KINDS), name: "ck_ombudsman_events_kind"
    add_check_constraint :ombudsman_events, in_list("actor", ACTORS), name: "ck_ombudsman_events_actor"
    add_check_constraint :ombudsman_events, "(actor::text = 'staff'::text) = (actor_user_id IS NOT NULL)", name: "ck_ombudsman_events_actor_user"
    add_check_constraint :ombudsman_events, "jsonb_typeof(data) = 'object'::text", name: "ck_ombudsman_events_data"
  end

  def create_forwardings_and_accesses
    create_table :ombudsman_forwardings, id: :uuid do |t|
      t.references :ombudsman_manifestation, type: :uuid, null: false, foreign_key: true, index: false
      t.references :department, type: :uuid, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, foreign_key: true, index: false
      t.text :extract, null: false
      t.date :due_on, null: false
      t.boolean :extended, null: false, default: false
      t.text :extension_reason
      t.string :state, null: false
      t.text :reply
      t.references :replied_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :replied_at
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :ombudsman_forwardings, %i[ombudsman_manifestation_id created_at], name: "idx_ombudsman_forwardings_manifestation"
    add_index :ombudsman_forwardings, %i[state due_on], name: "idx_ombudsman_forwardings_state"
    add_check_constraint :ombudsman_forwardings, "num_nonnulls(department_id, health_unit_id) = 1", name: "ck_ombudsman_forwardings_destination"
    add_check_constraint :ombudsman_forwardings, in_list("state", FORWARDING_STATES), name: "ck_ombudsman_forwardings_state"
    # O motivo do `decline` também vai em reply (Q9/A11).
    add_check_constraint :ombudsman_forwardings,
                         "(state::text = ANY (ARRAY['replied'::text, 'declined'::text])) = (reply IS NOT NULL)",
                         name: "ck_ombudsman_forwardings_reply"

    create_table :ombudsman_identity_accesses, id: :uuid do |t|
      t.references :ombudsman_manifestation, type: :uuid, null: false, foreign_key: true, index: false
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.text :justification, null: false
      t.string :scope, null: false
      t.references :exam_file, type: :uuid, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :ombudsman_identity_accesses, %i[ombudsman_manifestation_id created_at], name: "idx_ombudsman_identity_accesses_manifestation"
    add_check_constraint :ombudsman_identity_accesses, in_list("scope", ACCESS_SCOPES), name: "ck_ombudsman_identity_accesses_scope"
    add_check_constraint :ombudsman_identity_accesses, "(scope::text = 'attachment'::text) = (exam_file_id IS NOT NULL)",
                         name: "ck_ombudsman_identity_accesses_file"

    create_table :ombudsman_attachments, id: :uuid do |t|
      t.references :ombudsman_manifestation, type: :uuid, foreign_key: true, index: false
      t.references :exam_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.text :filename, null: false
      t.string :uploaded_by, null: false
      # Sem FK: a sessão é apagada pelo PurgeCitizenChannelJob.
      t.uuid :citizen_session_id
      t.references :uploaded_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.references :event, type: :uuid, foreign_key: { to_table: :ombudsman_events }, index: false
      t.datetime :created_at, null: false
    end
    add_index :ombudsman_attachments, :exam_file_id, unique: true, name: "idx_ombudsman_attachments_file"
    add_index :ombudsman_attachments, :ombudsman_manifestation_id, name: "idx_ombudsman_attachments_manifestation"
    add_index :ombudsman_attachments, :created_at, where: "ombudsman_manifestation_id IS NULL", name: "idx_ombudsman_attachments_orphans"
    add_check_constraint :ombudsman_attachments, in_list("uploaded_by", UPLOADERS), name: "ck_ombudsman_attachments_uploaded_by"
    add_check_constraint :ombudsman_attachments,
                         "(uploaded_by::text = 'citizen'::text) = (citizen_session_id IS NOT NULL) AND " \
                         "(uploaded_by::text = 'staff'::text) = (uploaded_by_user_id IS NOT NULL)",
                         name: "ck_ombudsman_attachments_owner"
  end

  def create_citizen_side
    create_table :ombudsman_reopen_requests, id: :uuid do |t|
      t.references :ombudsman_manifestation, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :cycle, null: false
      t.text :reason, null: false
      t.string :state, null: false
      t.text :decision_text
      t.references :decided_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :decided_at
      t.timestamps
    end
    add_index :ombudsman_reopen_requests, :ombudsman_manifestation_id, unique: true, where: "state::text = 'pending'::text",
                                                                       name: "idx_ombudsman_reopen_requests_pending"
    add_index :ombudsman_reopen_requests, %i[ombudsman_manifestation_id cycle], unique: true, name: "idx_ombudsman_reopen_requests_cycle"
    add_check_constraint :ombudsman_reopen_requests, in_list("state", REOPEN_STATES), name: "ck_ombudsman_reopen_requests_state"
    add_check_constraint :ombudsman_reopen_requests,
                         "(state::text = 'pending'::text) = (decided_at IS NULL AND decided_by_user_id IS NULL)",
                         name: "ck_ombudsman_reopen_requests_decided"

    create_table :ombudsman_satisfaction_responses, id: :uuid do |t|
      t.references :ombudsman_manifestation, type: :uuid, null: false, foreign_key: true, index: false
      t.string :met, null: false
      t.boolean :clear, null: false
      t.integer :score, null: false
      t.datetime :created_at, null: false
    end
    add_index :ombudsman_satisfaction_responses, :ombudsman_manifestation_id, unique: true,
                                                                              name: "idx_ombudsman_satisfaction_responses_manifestation"
    add_check_constraint :ombudsman_satisfaction_responses, in_list("met", MET), name: "ck_ombudsman_satisfaction_responses_met"
    add_check_constraint :ombudsman_satisfaction_responses, "score >= 1 AND score <= 5", name: "ck_ombudsman_satisfaction_responses_score"

    create_table :ombudsman_notices, id: :uuid do |t|
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: false
      t.references :ombudsman_manifestation, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.datetime :read_at
      t.datetime :created_at, null: false
    end
    add_index :ombudsman_notices, %i[citizen_id read_at], name: "idx_ombudsman_notices_citizen"
    add_index :ombudsman_notices, :ombudsman_manifestation_id, name: "idx_ombudsman_notices_manifestation"
    add_check_constraint :ombudsman_notices, in_list("kind", NOTICE_KINDS), name: "ck_ombudsman_notices_kind"
  end

  def create_reports
    create_table :ombudsman_annual_reports, id: :uuid do |t|
      t.integer :year, null: false
      t.text :recurring_problems
      t.text :actions_taken
      t.text :notes
      t.string :state, null: false
      t.jsonb :snapshot
      t.references :published_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :published_at
      t.timestamps
    end
    add_index :ombudsman_annual_reports, :year, unique: true, name: "idx_ombudsman_annual_reports_year"
    add_check_constraint :ombudsman_annual_reports, "year >= 2000 AND year <= 2999", name: "ck_ombudsman_annual_reports_year"
    add_check_constraint :ombudsman_annual_reports, in_list("state", REPORT_STATES), name: "ck_ombudsman_annual_reports_state"
    add_check_constraint :ombudsman_annual_reports,
                         "(state::text = 'published'::text) = (published_at IS NOT NULL AND snapshot IS NOT NULL)",
                         name: "ck_ombudsman_annual_reports_published"

    create_table :ombudsman_daily_runs, id: :uuid do |t|
      t.date :run_on, null: false
      t.string :kind, limit: 30, null: false
      t.datetime :created_at, null: false
    end
    add_index :ombudsman_daily_runs, %i[run_on kind], unique: true, name: "idx_ombudsman_daily_runs_once"
    add_check_constraint :ombudsman_daily_runs, in_list("kind", DAILY_RUN_KINDS), name: "ck_ombudsman_daily_runs_kind"
  end

  # A linha de configuração e a árvore de assuntos (tabela recém-criada, vazia).
  def seed
    execute "INSERT INTO ombudsman_settings (id, updated_at) VALUES (1, now()) ON CONFLICT (id) DO NOTHING"
    SUBJECT_TREE.each_with_index do |(name, children), index|
      parent_id = select_value("INSERT INTO ombudsman_subjects (name, position, created_at, updated_at) " \
                               "VALUES (#{quote(name)}, #{index + 1}, now(), now()) RETURNING id")
      children.each_with_index do |child, child_index|
        execute "INSERT INTO ombudsman_subjects (name, parent_id, position, created_at, updated_at) " \
                "VALUES (#{quote(child)}, #{quote(parent_id)}, #{child_index + 1}, now(), now())"
      end
    end
  end

  def in_list(column, list) = "#{column}::text = ANY (ARRAY[#{list.map { |value| "'#{value}'::text" }.join(', ')}])"
  def quote(value) = connection.quote(value)
end
