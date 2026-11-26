# Módulo 26c (MIRA; plano, Task 5; contrato; Valor 4; Q6, Q16, Q17): o envio
# da regulação à RNDS.
#   - regulation_rnds_settings: uma linha só (id 1, molde do bnafar_settings):
#     o caráter por cor, o SIGTAP por especialidade, o envio dos regulados
#     pelo estado, a versão (concorrência otimista) e quem trocou por último;
#   - regulation_rnds_syncs: o estado do envio de cada pedido (um por pedido):
#     o identificador do Bundle (Q6: texto, cabe o marcador do simulado), o
#     último documento aceito, as situações MIRA enviada e desejada com as
#     impressões digitais, os passos pendentes, a situação da linha, os
#     motivos de bloqueio, os códigos de erro (só o código), as tentativas, o
#     cursor (`enqueued_at`) e o token do claim (`claimed_at`, Q6);
#   - regulation_rnds_deliveries: cada chamada à RNDS (create, replace,
#     delete), com o payload cifrado (CityEncryption; NULL no delete e depois
#     de 30 dias, Q17) e a resposta (status HTTP, id RNDS, códigos, aceite);
#   - care_offers.performer_cbo e care_providers.default_performer_cbo: o CBO
#     do executante (decisão 14, Q2, Q12), 6 dígitos ou nulo;
#   - regulation_request_events.scheduled_at, ends_at e care_provider_id (Q24):
#     a linha `missed` guarda o horário e o prestador que a falta limpa do
#     pedido (nulos nas outras linhas e nas faltas de antes); a linha segue só
#     acréscimo (o trigger de re-cifra não muda);
#   - integration_credentials: o tipo aceita rnds_regulation (sempre
#     production: o CHECK de ambiente do 27b fica como está).
# Triggers em db/city_triggers.sql (bloco "Módulo 26c"; o dump não representa
# trigger). Irreversível.
class AddRegulationRnds < ActiveRecord::Migration[8.1]
  # Espelhos de Regulation::RndsCatalog e IntegrationCredential::KINDS no dia
  # desta migração (a migração não lê código da aplicação: a lista do banco
  # fica fixa).
  MIRA_STATUSES = %w[pending booked attended cancelled absence excluded returned-to-requester].freeze
  SYNC_STATUSES = %w[idle queued sending blocked rejected failed excluded erased].freeze
  DELIVERY_KINDS = %w[create replace delete].freeze
  DEFAULT_PRIORITY_BY_COLOR = { "red" => "urgent", "yellow" => "routine", "green" => "routine", "blue" => "routine" }.freeze
  CREDENTIAL_KINDS = %w[ledi cadsus rnds bnafar rnds_regulation].freeze
  DUE_STATUSES = %w[queued blocked sending].freeze

  def up
    create_settings
    create_syncs
    create_deliveries
    change_performers
    add_miss_schedule
    replace_check :integration_credentials, "ck_integration_credentials_kind", in_list("kind", CREDENTIAL_KINDS)

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_settings
    create_table :regulation_rnds_settings, id: :smallint do |t|
      t.jsonb :priority_by_color, null: false, default: DEFAULT_PRIORITY_BY_COLOR
      t.jsonb :specialty_sigtap, null: false, default: {}
      t.boolean :send_external, null: false, default: false
      t.integer :version, null: false, default: 1
      t.references :updated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :updated_at, null: false
    end
    add_check_constraint :regulation_rnds_settings, "id = 1", name: "ck_regulation_rnds_settings_singleton"
    execute "INSERT INTO regulation_rnds_settings (id, updated_at) VALUES (1, now())"
  end

  def create_syncs
    create_table :regulation_rnds_syncs, id: :uuid do |t|
      t.references :regulation_request, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :bundle_identifier, null: false, limit: 64
      t.string :last_rnds_id, limit: 100
      t.datetime :last_accepted_at
      t.string :sent_status
      t.string :sent_digest, limit: 64
      t.string :desired_status
      t.string :desired_digest, limit: 64
      t.jsonb :pending_steps, null: false, default: []
      t.string :status, null: false
      t.text :blocked_reasons, array: true, null: false, default: []
      t.text :last_error_codes, array: true, null: false, default: []
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.boolean :initial_load, null: false, default: false
      t.datetime :enqueued_at, null: false
      t.datetime :claimed_at
      t.timestamps
    end
    add_index :regulation_rnds_syncs, :bundle_identifier, unique: true, name: "idx_regulation_rnds_syncs_bundle_identifier"
    add_index :regulation_rnds_syncs, %i[status next_attempt_at], where: "status::text = ANY (ARRAY[#{quoted(DUE_STATUSES)}])",
                                                                   name: "idx_regulation_rnds_syncs_due"
    add_check_constraint :regulation_rnds_syncs, "bundle_identifier::text ~ '^[A-Za-z0-9_-]{1,64}$'::text",
                         name: "ck_regulation_rnds_syncs_bundle_identifier"
    add_check_constraint :regulation_rnds_syncs, in_list("status", SYNC_STATUSES), name: "ck_regulation_rnds_syncs_status"
    add_check_constraint :regulation_rnds_syncs, "sent_status IS NULL OR #{in_list('sent_status', MIRA_STATUSES)}",
                         name: "ck_regulation_rnds_syncs_sent_status"
    add_check_constraint :regulation_rnds_syncs, "desired_status IS NULL OR #{in_list('desired_status', MIRA_STATUSES)}",
                         name: "ck_regulation_rnds_syncs_desired_status"
  end

  def create_deliveries
    create_table :regulation_rnds_deliveries, id: :uuid do |t|
      t.references :regulation_rnds_sync, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.string :mira_status
      t.text :payload
      t.string :digest, limit: 64
      t.string :rnds_id, limit: 100
      t.integer :http_status
      t.text :error_codes, array: true, null: false, default: []
      t.datetime :sent_at, null: false
      t.datetime :accepted_at
    end
    add_index :regulation_rnds_deliveries, %i[regulation_rnds_sync_id sent_at], name: "idx_regulation_rnds_deliveries_sync"
    add_check_constraint :regulation_rnds_deliveries, in_list("kind", DELIVERY_KINDS), name: "ck_regulation_rnds_deliveries_kind"
    add_check_constraint :regulation_rnds_deliveries, "mira_status IS NULL OR #{in_list('mira_status', MIRA_STATUSES)}",
                         name: "ck_regulation_rnds_deliveries_mira_status"
  end

  def change_performers
    add_column :care_offers, :performer_cbo, :string, limit: 6
    add_check_constraint :care_offers, "performer_cbo IS NULL OR performer_cbo::text ~ '^[0-9]{6}$'::text",
                         name: "ck_care_offers_performer_cbo"
    add_column :care_providers, :default_performer_cbo, :string, limit: 6
    add_check_constraint :care_providers, "default_performer_cbo IS NULL OR default_performer_cbo::text ~ '^[0-9]{6}$'::text",
                         name: "ck_care_providers_default_performer_cbo"
  end

  def add_miss_schedule
    add_column :regulation_request_events, :scheduled_at, :timestamptz
    add_column :regulation_request_events, :ends_at, :timestamptz
    add_column :regulation_request_events, :care_provider_id, :uuid
    add_foreign_key :regulation_request_events, :care_providers
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")
  def in_list(column, list) = "#{column}::text = ANY (ARRAY[#{quoted(list)}])"

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
