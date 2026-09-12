# Schema inicial de um banco de CIDADE (Plano 2, Task 4 — "banco por cidade").
#
# NÃO fica em db/migrate: primary e admin (config/database.yml) apontam para o
# banco COMPARTILHADO e usam db/migrate como migrations_paths. Uma migration de
# domínio ali seria recriada em silêncio no banco compartilhado por qualquer
# `db:migrate`/`db:prepare` futuro. Este arquivo só é aplicado a bancos de
# cidade, via `city:load_schema` (lib/tasks/city.rake), que carrega o dump
# db/city_schema.rb — não este arquivo diretamente.
#
# Deriva de db/structure.sql (33 migrations acumuladas, lido antes de deletar
# em 2026-09-12 — ver task-4-context.md). Diferenças deliberadas em relação ao
# schema tenant antigo:
#   - nenhuma tabela tem `municipality_id`: cada cidade já É o escopo, então a
#     coluna e tudo que dependia dela (FKs para `municipalities`, índices de
#     tenant, RLS/policies, ownership rota_admin vs rota_app) desaparecem;
#   - `municipalities`, `municipality_channels` e `unknown_channels` NÃO
#     entram — viraram `cities`/`city_channels`/plataforma (Planos 1 e Task 3);
#   - `authors` fica, sem municipality_id (Ruling R8: bearer-token de protocolo,
#     não é redundante com `users`);
#   - `memberships` perde `ck_memberships_operator_global` inteira (não há mais
#     operador global dentro de uma cidade) e `ck_memberships_role` perde
#     `platform_operator` da lista de papéis válidos;
#   - índices que citavam municipality_id foram repensados, não só
#     desprovidos da coluna — ver o relatório da Task 4 para a lista completa
#     de decisões (ex.: unicidade por tenant+telefone em `conversations vira
#     unicidade só por telefone, já que o banco inteiro é uma cidade).
class CreateCitySchema < ActiveRecord::Migration[8.1]
  def change
    enable_extension "citext"
    enable_extension "pgcrypto"

    create_table :alert_recipients, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean :active, default: true, null: false
      t.string :channel, null: false
      t.string :destination, null: false
      t.integer :escalation_order, default: 0, null: false
      t.timestamps

      t.check_constraint "channel::text = ANY (ARRAY['whatsapp'::character varying::text, 'email'::character varying::text])",
                          name: "ck_alert_recipients_channel"
    end
    add_index :alert_recipients, :escalation_order, name: "index_alert_recipients_on_escalation_order"

    create_table :authors, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :email, null: false
      t.string :name
      t.string :token, null: false
      t.timestamps
    end
    add_index :authors, :email, unique: true, name: "index_authors_on_email"
    add_index :authors, :token, unique: true, name: "index_authors_on_token"

    create_table :consent_terms, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.text :body, null: false
      t.datetime :published_at, null: false
      t.string :version, null: false
      t.timestamps
    end
    add_index :consent_terms, :version, unique: true, name: "index_consent_terms_on_version"

    create_table :conversations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :phone, null: false
      t.string :state, null: false, default: "greeting"
      t.timestamps
    end
    add_index :conversations, :state, name: "index_conversations_on_state"
    add_index :conversations, :phone,
              unique: true,
              where: "(state)::text = ANY (ARRAY[('awaiting_consent'::character varying)::text, ('consented'::character varying)::text, ('greeting'::character varying)::text])",
              name: "idx_conversations_active_phone"

    create_table :consents, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :channel, null: false
      t.uuid :conversation_id, null: false
      t.text :evidence
      t.datetime :given_at, null: false
      t.string :policy_text_sha, null: false
      t.datetime :revoked_at
      t.integer :version, null: false
      t.timestamps
    end
    add_index :consents, :conversation_id, name: "index_consents_on_conversation_id"
    add_index :consents, :given_at, name: "index_consents_on_given_at"
    add_index :consents, [:conversation_id, :revoked_at],
              unique: true,
              where: "revoked_at IS NULL",
              name: "idx_consents_one_active_per_conversation"
    add_foreign_key :consents, :conversations

    create_table :dashboard_metrics, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :dimension, null: false
      t.string :key, null: false
      t.string :period, null: false
      t.integer :value, null: false, default: 0
      t.timestamps
    end
    add_index :dashboard_metrics, [:dimension, :period], name: "index_dashboard_metrics_on_dimension_and_period"
    add_index :dashboard_metrics, [:dimension, :period, :key],
              unique: true,
              name: "idx_dashboard_metrics_dim_period_key"

    create_table :domain_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :published_at
      t.timestamps
    end
    add_index :domain_events, :name, name: "index_domain_events_on_name"
    add_index :domain_events, :occurred_at, name: "index_domain_events_on_occurred_at"
    add_index :domain_events, :occurred_at, where: "published_at IS NULL", name: "idx_domain_events_pending"

    create_table :identities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :provider, null: false
      t.string :provider_uid, null: false
      t.uuid :user_id, null: false
      t.timestamps
    end
    add_index :identities, [:provider, :provider_uid], unique: true, name: "index_identities_on_provider_and_provider_uid"
    add_index :identities, :user_id, name: "index_identities_on_user_id"

    create_table :inbound_messages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :from, null: false
      t.string :kind, null: false
      t.string :message_id, null: false
      t.text :raw, null: false
      t.timestamps
    end
    add_index :inbound_messages, :created_at, name: "index_inbound_messages_on_created_at"
    add_index :inbound_messages, :from, name: "index_inbound_messages_on_from"
    add_index :inbound_messages, :message_id, unique: true, name: "index_inbound_messages_on_message_id"

    create_table :invitations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.datetime :accepted_at
      t.string :email, null: false
      t.datetime :expires_at, null: false
      t.uuid :invited_by_id, null: false
      t.string :role, null: false
      t.string :token, null: false
      t.timestamps
    end
    add_index :invitations, :invited_by_id, name: "index_invitations_on_invited_by_id"
    add_index :invitations, :token, unique: true, name: "index_invitations_on_token"

    create_table :memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.datetime :granted_at, null: false
      t.uuid :granted_by_id
      t.datetime :revoked_at
      t.string :role, null: false
      t.uuid :user_id, null: false
      t.timestamps

      t.check_constraint "role::text = ANY (ARRAY['municipal_admin'::character varying::text, 'protocol_author'::character varying::text, 'protocol_publisher'::character varying::text, 'viewer'::character varying::text])",
                          name: "ck_memberships_role"
    end
    add_index :memberships, :granted_by_id, name: "index_memberships_on_granted_by_id"
    add_index :memberships, :user_id, name: "index_memberships_on_user_id"
    add_index :memberships, [:user_id, :role],
              unique: true,
              where: "revoked_at IS NULL",
              name: "idx_memberships_unique_active"

    create_table :outbound_messages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.jsonb :context, null: false, default: {}
      t.string :idempotency_key, null: false
      t.text :response
      t.integer :status, null: false
      t.jsonb :template, null: false
      t.string :to, null: false
      t.timestamps
    end
    add_index :outbound_messages, :idempotency_key, unique: true, name: "index_outbound_messages_on_idempotency_key"
    add_index :outbound_messages, [:status, :created_at], name: "index_outbound_messages_on_status_and_created_at"
    add_index :outbound_messages, :to, name: "index_outbound_messages_on_to"

    create_table :processed_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :consumer, null: false
      t.string :event_id, null: false
      t.datetime :processed_at, null: false
      t.timestamps
    end
    add_index :processed_events, [:consumer, :event_id], unique: true, name: "index_processed_events_on_consumer_and_event_id"
    add_index :processed_events, :processed_at, name: "index_processed_events_on_processed_at"

    create_table :protocol_definitions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.datetime :activated_at
      t.jsonb :definition, null: false
      t.string :name, null: false
      t.datetime :retired_at
      t.string :status, null: false, default: "draft"
      t.integer :version, null: false
      t.timestamps

      t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'in_review'::character varying::text, 'published'::character varying::text, 'active'::character varying::text, 'retired'::character varying::text])",
                          name: "ck_protocol_definitions_status"
    end
    add_index :protocol_definitions, [:name, :version], unique: true, name: "idx_protocol_definitions_name_version_muni"
    add_index :protocol_definitions, :name,
              unique: true,
              where: "(status)::text = 'active'::text",
              name: "idx_protocol_definitions_one_active_per_name_muni"

    create_table :report_snapshots, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.datetime :expires_at
      t.jsonb :outcome, null: false
      t.jsonb :payload, null: false
      t.uuid :protocol_definition_id, null: false
      t.string :signature, null: false
      t.string :token, null: false
      t.uuid :triage_id, null: false
      t.timestamps
    end
    add_index :report_snapshots, :expires_at, name: "index_report_snapshots_on_expires_at"
    add_index :report_snapshots, :protocol_definition_id, name: "index_report_snapshots_on_protocol_definition_id"
    add_index :report_snapshots, :token, unique: true, name: "index_report_snapshots_on_token"
    add_index :report_snapshots, :triage_id, name: "index_report_snapshots_on_triage_id"
    add_index :report_snapshots, :triage_id, unique: true, name: "idx_report_snapshots_one_per_triagem"
    add_foreign_key :report_snapshots, :protocol_definitions
    # fk para :triages fica no fim do arquivo — a tabela só existe mais abaixo.

    create_table :sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :ip_address
      t.datetime :mfa_verified_at
      t.string :user_agent
      t.uuid :user_id, null: false
      t.timestamps
    end
    add_index :sessions, :user_id, name: "index_sessions_on_user_id"

    create_table :triages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.jsonb :answers, null: false, default: {}
      t.datetime :completed_at
      t.uuid :conversation_id, null: false
      t.string :current_step
      t.jsonb :outcome
      t.integer :priority
      t.uuid :protocol_definition_id, null: false
      t.string :protocol_name, null: false
      t.string :status, null: false, default: "in_progress"
      t.string :tier
      t.timestamps

      t.check_constraint "status::text = ANY (ARRAY['in_progress'::character varying::text, 'completed'::character varying::text, 'aborted_by_revocation'::character varying::text])",
                          name: "ck_triagens_status"
    end
    add_index :triages, :conversation_id, name: "index_triages_on_conversation_id"
    add_index :triages, [:conversation_id, :created_at], name: "index_triages_on_conversation_id_and_created_at"
    add_index :triages, [:conversation_id, :status], name: "index_triages_on_conversation_id_and_status"
    add_index :triages, :protocol_definition_id, name: "index_triages_on_protocol_definition_id"
    add_index :triages, :status, name: "index_triages_on_status"
    add_index :triages, :tier, name: "index_triages_on_tier"
    add_index :triages, :conversation_id,
              unique: true,
              where: "(status)::text = 'in_progress'::text",
              name: "idx_triagens_one_in_progress_per_conversation"
    add_foreign_key :triages, :conversations
    add_foreign_key :triages, :protocol_definitions

    create_table :users, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.datetime :deactivated_at
      t.string :email_address, null: false
      t.boolean :otp_enabled, null: false, default: false
      t.jsonb :otp_recovery_codes, null: false, default: []
      t.string :otp_secret
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :users, "lower(email_address)", unique: true, name: "index_users_on_lower_email"

    add_foreign_key :identities, :users
    add_foreign_key :invitations, :users, column: :invited_by_id
    add_foreign_key :memberships, :users, column: :granted_by_id
    add_foreign_key :memberships, :users
    add_foreign_key :sessions, :users
    add_foreign_key :report_snapshots, :triages
  end
end
