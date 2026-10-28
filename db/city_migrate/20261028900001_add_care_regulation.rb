# Módulo 26a (ADR 0044): regulação municipal. Papel care_regulator; prestadores
# (rede própria, contratado, consórcio, PPI) e ofertas mensais com cota; prazos
# por cor (os 4 padrões inseridos aqui); lista do enfermeiro; o pedido de
# regulação (estado atual com `version`; rascunho na consulta é uma linha
# `draft`), o andamento (só acréscimo, motivo cifrado; `missed` só aqui, nunca
# como situação atual, contrato §13 G1) e as autorizações (uma por
# autorização; a cota usada é a contagem das não liberadas). O pedido de
# agendamento do 17 ganha a origem no pedido de regulação (kind regulated, sem
# triagem raiz, como o da linha de cuidado). Triggers em db/city_triggers.sql
# (o dump não representa trigger). Irreversível.
class AddCareRegulation < ActiveRecord::Migration[8.1]
  ROLES = %w[analyst billing_clerk campaign_manager care_regulator citizen_verifier exam_provider exam_regulator health_professional
             lab_releaser lab_staff municipal_admin protocol_author protocol_publisher protocol_reviewer surveillance viewer].freeze
  # Espelho de CareRegulation::Catalog no dia desta migração (a migração não lê
  # código da aplicação: a lista do banco fica fixa no que foi migrado).
  TYPES = %w[specialty procedure].freeze
  COLORS = %w[red yellow green blue].freeze
  STATUSES = %w[draft pending returned authorized scheduled completed missed denied cancelled closed external].freeze
  PROVIDER_KINDS = %w[own contracted consortium ppi].freeze
  EXTERNAL_SYSTEMS = %w[sisreg care cross other].freeze
  RELEASE_REASONS = %w[cancelled citizen_cancelled unit_dismissed consent_revoked].freeze
  DEFAULT_DEADLINE_DAYS = { "red" => 7, "yellow" => 30, "green" => 90, "blue" => 180 }.freeze
  APPOINTMENT_KINDS = %w[return referral triage screening care_line regulated].freeze

  def up
    replace_check :memberships, "ck_memberships_role", "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])"

    create_table :care_providers, id: :uuid do |t|
      t.string :name, limit: 120, null: false
      t.string :cnes, limit: 7
      t.string :kind, null: false
      t.references :health_unit, type: :uuid, foreign_key: true, index: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :care_providers, :cnes, unique: true, where: "cnes IS NOT NULL", name: "idx_care_providers_cnes"
    add_index :care_providers, :health_unit_id, unique: true, where: "health_unit_id IS NOT NULL", name: "idx_care_providers_unit"
    add_check_constraint :care_providers, "cnes IS NULL OR cnes::text ~ '^[0-9]{7}$'::text", name: "ck_care_providers_cnes"
    add_check_constraint :care_providers, "kind::text = 'own'::text OR cnes IS NOT NULL", name: "ck_care_providers_cnes_required"
    add_check_constraint :care_providers, "kind::text = ANY (ARRAY[#{quoted(PROVIDER_KINDS)}]::text[])", name: "ck_care_providers_kind"
    add_check_constraint :care_providers, "(kind::text = 'own'::text) = (health_unit_id IS NOT NULL)", name: "ck_care_providers_unit"

    create_table :care_offers, id: :uuid do |t|
      t.references :care_provider, type: :uuid, null: false, foreign_key: true, index: false
      t.string :target_type, null: false
      t.string :target_code, limit: 10, null: false
      t.date :month, null: false
      t.integer :quantity, null: false
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :care_offers, %i[care_provider_id target_type target_code month], unique: true, name: "idx_care_offers_unique"
    add_index :care_offers, %i[target_type target_code month], name: "idx_care_offers_target_month"
    add_check_constraint :care_offers, "target_type::text = ANY (ARRAY[#{quoted(TYPES)}]::text[])", name: "ck_care_offers_target_type"
    add_check_constraint :care_offers, "month = date_trunc('month'::text, month::timestamp without time zone)::date", name: "ck_care_offers_month"
    add_check_constraint :care_offers, "quantity >= 0 AND quantity <= 9999", name: "ck_care_offers_quantity"

    create_table :regulation_risk_deadlines, id: :string, primary_key: :color do |t|
      t.integer :days, null: false
      t.references :updated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :updated_at, null: false
    end
    add_check_constraint :regulation_risk_deadlines, "color::text = ANY (ARRAY[#{quoted(COLORS)}]::text[])",
                         name: "ck_regulation_risk_deadlines_color"
    add_check_constraint :regulation_risk_deadlines, "days >= 1 AND days <= 365", name: "ck_regulation_risk_deadlines_days"
    DEFAULT_DEADLINE_DAYS.each do |color, days|
      execute "INSERT INTO regulation_risk_deadlines (color, days, updated_at) VALUES (#{connection.quote(color)}, #{Integer(days)}, now()) " \
              "ON CONFLICT (color) DO NOTHING"
    end

    create_table :nurse_requestable_items, id: :uuid do |t|
      t.string :target_type, null: false
      t.string :target_code, limit: 10, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :nurse_requestable_items, %i[target_type target_code], unique: true, name: "idx_nurse_requestable_items_target"
    add_check_constraint :nurse_requestable_items, "target_type::text = ANY (ARRAY[#{quoted(TYPES)}]::text[])",
                         name: "ck_nurse_requestable_items_target_type"

    create_table :regulation_requests, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: true
      t.references :consultation, type: :uuid, null: false, foreign_key: true, index: true
      t.references :addendum, type: :uuid, foreign_key: { to_table: :consultation_addenda }, index: false
      t.references :requester_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.string :requester_cbo, limit: 6, null: false
      t.references :requester_unit, type: :uuid, null: false, foreign_key: { to_table: :health_units }, index: false
      t.string :target_type, null: false
      t.string :target_code, limit: 10, null: false
      t.string :target_name, limit: 250, null: false
      # Cifrados com a chave da cidade (CityEncryption::CITY_KEYED_TARGETS).
      # cid10 e ciap2 aceitam nulo: quem pode pedir sem CID-10 manda o CIAP-2
      # (contrato §13 G10); a regra é do serviço.
      t.text :cid10
      t.text :ciap2
      t.text :justification, null: false
      t.string :suggested_color, null: false
      t.string :color
      t.text :color_reason
      t.string :status, null: false
      t.boolean :state_regulated, null: false, default: false
      t.string :external_system
      t.string :external_number, limit: 30
      t.timestamptz :requested_at
      t.date :due_on
      t.integer :misses, null: false, default: 0
      t.references :appointment_request, type: :uuid, foreign_key: true, index: false
      t.timestamptz :scheduled_at
      t.string :schedule_place, limit: 200
      t.text :schedule_notes
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :regulation_requests, %i[status target_type target_code requested_at], name: "idx_regulation_requests_queue"
    add_index :regulation_requests, %i[requester_unit_id status], name: "idx_regulation_requests_unit_status"
    add_index :regulation_requests, :appointment_request_id, unique: true, where: "appointment_request_id IS NOT NULL",
                                                             name: "idx_regulation_requests_appointment_request"
    add_check_constraint :regulation_requests, "target_type::text = ANY (ARRAY[#{quoted(TYPES)}]::text[])",
                         name: "ck_regulation_requests_target_type"
    add_check_constraint :regulation_requests, "suggested_color::text = ANY (ARRAY[#{quoted(COLORS)}]::text[])",
                         name: "ck_regulation_requests_suggested_color"
    add_check_constraint :regulation_requests, "color IS NULL OR color::text = ANY (ARRAY[#{quoted(COLORS)}]::text[])",
                         name: "ck_regulation_requests_color"
    add_check_constraint :regulation_requests, "status::text = ANY (ARRAY[#{quoted(STATUSES - %w[missed])}]::text[])",
                         name: "ck_regulation_requests_status"
    add_check_constraint :regulation_requests,
                         "external_system IS NULL OR external_system::text = ANY (ARRAY[#{quoted(EXTERNAL_SYSTEMS)}]::text[])",
                         name: "ck_regulation_requests_external_system"
    add_check_constraint :regulation_requests, "(external_system IS NULL) = (external_number IS NULL)",
                         name: "ck_regulation_requests_external_number"
    add_check_constraint :regulation_requests, "(status::text = 'draft'::text) = (requested_at IS NULL)",
                         name: "ck_regulation_requests_requested_at"
    add_check_constraint :regulation_requests, "(status::text = 'draft'::text) = (due_on IS NULL)", name: "ck_regulation_requests_due_on"
    add_check_constraint :regulation_requests, "misses >= 0 AND misses <= 2", name: "ck_regulation_requests_misses"
    add_check_constraint :regulation_requests, "version >= 1", name: "ck_regulation_requests_version"

    create_table :regulation_request_events, id: :uuid do |t|
      t.references :regulation_request, type: :uuid, null: false, foreign_key: true, index: true
      t.string :status, null: false
      t.references :by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :reason
      t.datetime :created_at, null: false
    end
    add_check_constraint :regulation_request_events, "status::text = ANY (ARRAY[#{quoted(STATUSES - %w[draft])}]::text[])",
                         name: "ck_regulation_request_events_status"

    create_table :regulation_authorizations, id: :uuid do |t|
      t.references :regulation_request, type: :uuid, null: false, foreign_key: true, index: true
      t.references :care_offer, type: :uuid, null: false, foreign_key: true, index: false
      t.date :month, null: false
      t.text :skip_reason
      t.references :authorized_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
      t.datetime :released_at
      t.string :release_reason
    end
    add_index :regulation_authorizations, :care_offer_id, where: "released_at IS NULL", name: "idx_regulation_authorizations_used"
    add_check_constraint :regulation_authorizations,
                         "release_reason IS NULL OR release_reason::text = ANY (ARRAY[#{quoted(RELEASE_REASONS)}]::text[])",
                         name: "ck_regulation_authorizations_release_reason"
    add_check_constraint :regulation_authorizations, "(released_at IS NULL) = (release_reason IS NULL)",
                         name: "ck_regulation_authorizations_released"

    # Pedido de agendamento do 17 com origem no pedido de regulação (rede
    # própria): sem triagem raiz e com as duas unidades, como o da linha de
    # cuidado; um vivo por pedido de regulação.
    add_reference :appointment_requests, :origin_regulation_request, type: :uuid, index: false,
                                                                     foreign_key: { to_table: :regulation_requests }
    add_index :appointment_requests, :origin_regulation_request_id, unique: true,
              where: "origin_regulation_request_id IS NOT NULL AND status::text = ANY (ARRAY['open'::text, 'scheduled'::text])",
              name: "idx_appointment_requests_one_live_regulated"
    replace_check :appointment_requests, "ck_appointment_requests_kind", "kind::text = ANY (ARRAY[#{quoted(APPOINTMENT_KINDS)}]::text[])"
    replace_check :appointment_requests, "ck_appointment_requests_origin",
                  "num_nonnulls(origin_attendance_id, origin_triage_id, origin_care_line_enrollment_id, origin_regulation_request_id) = 1"
    replace_check :appointment_requests, "ck_appointment_requests_care_line",
                  "((kind)::text = 'care_line'::text) = (origin_care_line_enrollment_id IS NOT NULL) AND " \
                  "((kind)::text = ANY (ARRAY['care_line'::text, 'regulated'::text]) OR origin_attendance_id IS NOT NULL OR root_triage_id IS NOT NULL) AND " \
                  "((kind)::text <> ALL (ARRAY['care_line'::text, 'regulated'::text]) OR (origin_unit_id IS NOT NULL AND target_unit_id IS NOT NULL))"
    add_check_constraint :appointment_requests, "((kind)::text = 'regulated'::text) = (origin_regulation_request_id IS NOT NULL)",
                         name: "ck_appointment_requests_regulated"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
