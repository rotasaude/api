# Módulo 31 (ADR 0049): atenção psicossocial (CAPS). O CAPS é um tipo de
# unidade com modalidade (e a classificação do serviço do CNES); toda unidade
# ganha o telefone (contrato P27). Parâmetros (uma linha, id 1, inserida aqui:
# limites do acolhimento noturno por modalidade e o prazo de revisão do PTS),
# leitos, grade de grupos, encaminhamento da UBS, acolhimento, matrícula (uma
# aberta por paciente e CAPS), PTS com versões (só acréscimo) e o aviso de
# revisão, ações imutáveis (só o cancelamento) com os participantes, RAAS do
# mês com a foto do fechamento, fechamento do mês (reaberto uma vez), remessa,
# matriciamento com os casos compartilhados e a permanência no leito —
# exclusion GiST sobre tsrange(started_at, ended_at ou infinito): meio-aberto,
# quem sai às 08:00 e quem entra às 08:00 não se cruzam; a aberta ocupa o leito
# até fechar. Mês da ação e da RAAS é o dia 1º (o mês local vem do Ruby). CID,
# substâncias, evolução, PTS, motivos, nome do familiar, tema e texto do
# matriciamento, a foto e o arquivo da remessa: cifrados com a chave da cidade.
# Os limites de texto (P12) ficam nos comandos: o cifrado não tem o tamanho do
# claro. Triggers em db/city_triggers.sql (o dump não representa trigger nem
# linha). Irreversível.
class AddPsychosocialCare < ActiveRecord::Migration[8.1]
  ROLES = %w[analyst billing_clerk campaign_manager care_regulator citizen_verifier driver exam_provider exam_regulator
             health_professional lab_releaser lab_staff municipal_admin pharmacist pharmacy_assistant protocol_author
             protocol_publisher protocol_reviewer psychosocial_lead psychosocial_staff stock_keeper surveillance tfd_committee
             transport_dispatcher viewer].freeze
  HEALTH_UNIT_KINDS = %w[ubs upa hospital other ceo health_management caps].freeze
  # Espelho de HealthUnit e de Psychosocial::Catalog no dia desta migração (a
  # migração não lê código da aplicação: a lista do banco fica fixa no que foi
  # migrado).
  CAPS_MODALITIES = %w[caps_i caps_ii caps_iii caps_i_child caps_ad caps_ad_iii caps_ad_iv].freeze
  REFERRAL_PRIORITIES = %w[routine priority].freeze
  REFERRAL_STATUSES = %w[pending received].freeze
  RECEPTION_OUTCOMES = %w[enrolled referred_elsewhere no_follow_up].freeze
  PLACES = %w[caps territory].freeze
  INSTRUMENTS = %w[raas_psi bpa_c bpa_i].freeze
  GROUP_KINDS = %w[group workshop assembly].freeze
  INTENSITIES = %w[intensive semi_intensive non_intensive].freeze
  MONTHLY_STATUSES = %w[open closed exported].freeze
  ACTION_ORIGINS = %w[manual reception night_stay matrix_support].freeze
  WEEKDAYS = (1..7)
  QUANTITY = (1..999)
  CAPACITY = (1..100)
  REVIEW_DAYS = (30..365)
  DEFAULT_REVIEW_DAYS = 90
  DEFAULT_NIGHT_LIMITS = {
    "caps_iii" => { "consecutive" => 7, "alternate" => 10, "window_days" => 30 },
    "caps_ad_iii" => { "total" => 14, "window_days" => 30 },
    "caps_ad_iv" => { "total" => 14, "window_days" => 30 }
  }.freeze
  # As 16 tabelas do módulo (TRUNCATE recusado em todas).
  TABLES = %w[psychosocial_settings psychosocial_beds psychosocial_groups psychosocial_referrals psychosocial_receptions
              psychosocial_enrollments psychosocial_care_plans psychosocial_care_plan_alerts psychosocial_night_stays
              psychosocial_actions psychosocial_action_participants psychosocial_month_closures psychosocial_raas_exports
              psychosocial_monthly_records psychosocial_matrix_supports psychosocial_matrix_cases].freeze
  SIGTAP = "'^[0-9]{10}$'::text".freeze
  FIRST_DAY = "EXTRACT(day FROM month) = 1::numeric".freeze

  def up
    replace_check :memberships, "ck_memberships_role", "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])"
    change_health_units
    create_settings
    create_beds_and_groups
    create_referrals_and_enrollments
    create_night_stays
    create_actions
    create_months
    create_matrix_support

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def change_health_units
    replace_check :health_units, "ck_health_units_kind", "kind::text = ANY (ARRAY[#{quoted(HEALTH_UNIT_KINDS)}]::text[])"
    add_column :health_units, :caps_modality, :string
    add_column :health_units, :service_classification, :string, limit: 3
    add_column :health_units, :phone, :string, limit: 11
    add_check_constraint :health_units,
                         "(kind::text = 'caps'::text) = (caps_modality IS NOT NULL) AND " \
                         "(caps_modality IS NULL OR caps_modality::text = ANY (ARRAY[#{quoted(CAPS_MODALITIES)}]::text[])) AND " \
                         "(service_classification IS NULL OR (kind::text = 'caps'::text AND service_classification::text ~ '^[0-9]{3}$'::text))",
                         name: "ck_health_units_caps"
    add_check_constraint :health_units, "phone IS NULL OR phone::text ~ '^[0-9]{10,11}$'::text", name: "ck_health_units_phone"
  end

  def create_settings
    create_table :psychosocial_settings, id: :smallint do |t|
      t.jsonb :night_limits, null: false, default: DEFAULT_NIGHT_LIMITS
      t.integer :care_plan_review_days, null: false, default: DEFAULT_REVIEW_DAYS
      t.references :updated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :updated_at, null: false
    end
    add_check_constraint :psychosocial_settings, "id = 1", name: "ck_psychosocial_settings_singleton"
    add_check_constraint :psychosocial_settings, "jsonb_typeof(night_limits) = 'object'::text", name: "ck_psychosocial_settings_night_limits"
    add_check_constraint :psychosocial_settings,
                         "care_plan_review_days >= #{REVIEW_DAYS.min} AND care_plan_review_days <= #{REVIEW_DAYS.max}",
                         name: "ck_psychosocial_settings_review_days"
    execute "INSERT INTO psychosocial_settings (id, night_limits, updated_at) " \
            "VALUES (1, #{connection.quote(DEFAULT_NIGHT_LIMITS.to_json)}::jsonb, now()) ON CONFLICT (id) DO NOTHING"
  end

  def create_beds_and_groups
    create_table :psychosocial_beds, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :label, limit: 20, null: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :psychosocial_beds, %i[health_unit_id label], unique: true, name: "idx_psychosocial_beds_label"

    create_table :psychosocial_groups, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, limit: 120, null: false
      t.string :kind, null: false
      t.integer :weekday, limit: 2, null: false
      t.time :starts_at, null: false
      t.time :ends_at, null: false
      t.references :responsible_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.integer :capacity, null: false
      t.string :sigtap_code, limit: 10, null: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :psychosocial_groups, %i[health_unit_id weekday], name: "idx_psychosocial_groups_unit_weekday"
    add_check_constraint :psychosocial_groups,
                         "kind::text = ANY (ARRAY[#{quoted(GROUP_KINDS)}]::text[]) AND sigtap_code::text ~ #{SIGTAP} AND " \
                         "weekday >= #{WEEKDAYS.min} AND weekday <= #{WEEKDAYS.max} AND " \
                         "capacity >= #{CAPACITY.min} AND capacity <= #{CAPACITY.max}",
                         name: "ck_psychosocial_groups_domains"
    add_check_constraint :psychosocial_groups, "ends_at > starts_at", name: "ck_psychosocial_groups_times"
  end

  def create_referrals_and_enrollments
    create_table :psychosocial_referrals, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :from_health_unit, type: :uuid, null: false, foreign_key: { to_table: :health_units }, index: false
      # Motivo do encaminhamento: cifrado (a anonimização LGPD o leva a NULL).
      t.text :reason
      t.string :priority, null: false
      t.string :status, null: false, default: "pending"
      t.references :referred_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :received_at
      t.datetime :anonymized_at
      t.timestamps
    end
    add_index :psychosocial_referrals, %i[health_unit_id status created_at], name: "idx_psychosocial_referrals_queue"
    add_index :psychosocial_referrals, :patient_id, name: "idx_psychosocial_referrals_patient"
    add_check_constraint :psychosocial_referrals,
                         "priority::text = ANY (ARRAY[#{quoted(REFERRAL_PRIORITIES)}]::text[]) AND " \
                         "status::text = ANY (ARRAY[#{quoted(REFERRAL_STATUSES)}]::text[])",
                         name: "ck_psychosocial_referrals_domains"

    create_table :psychosocial_receptions, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :psychosocial_referral, type: :uuid, foreign_key: true, index: false
      t.datetime :at, null: false
      t.string :sigtap_code, limit: 10, null: false
      # Registro do acolhimento: cifrado (a anonimização LGPD o leva a NULL).
      t.text :notes
      t.string :outcome, null: false
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :anonymized_at
      t.datetime :created_at, null: false
    end
    add_index :psychosocial_receptions, :psychosocial_referral_id, unique: true, where: "psychosocial_referral_id IS NOT NULL",
                                                                   name: "idx_psychosocial_receptions_referral"
    add_index :psychosocial_receptions, %i[health_unit_id at], name: "idx_psychosocial_receptions_unit_at"
    add_index :psychosocial_receptions, :patient_id, name: "idx_psychosocial_receptions_patient"
    add_check_constraint :psychosocial_receptions,
                         "outcome::text = ANY (ARRAY[#{quoted(RECEPTION_OUTCOMES)}]::text[]) AND sigtap_code::text ~ #{SIGTAP}",
                         name: "ck_psychosocial_receptions_domains"

    create_table :psychosocial_enrollments, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :psychosocial_reception, type: :uuid, foreign_key: true, index: false
      t.date :started_on, null: false
      t.string :origin, limit: 2, null: false
      # CID principal, CIDs secundários (JSON) e substâncias (JSON): cifrados.
      t.text :cid_main, null: false
      t.text :cid_secondary
      t.text :substances
      t.boolean :esf_covered, null: false, default: false
      t.string :esf_cnes, limit: 7
      t.references :reference_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :next_visit_at
      t.string :destination, limit: 2
      t.date :closed_on
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :psychosocial_enrollments, %i[patient_id health_unit_id], unique: true, where: "closed_on IS NULL",
                                                                        name: "idx_psychosocial_enrollments_open"
    add_index :psychosocial_enrollments, %i[health_unit_id next_visit_at], name: "idx_psychosocial_enrollments_next_visit"
    add_index :psychosocial_enrollments, :patient_id, name: "idx_psychosocial_enrollments_patient"
    add_check_constraint :psychosocial_enrollments,
                         "origin::text ~ '^[0-9]{2}$'::text AND (destination IS NULL OR destination::text ~ '^[0-9]{2}$'::text) AND " \
                         "(esf_cnes IS NULL OR esf_cnes::text ~ '^[0-9]{7}$'::text)",
                         name: "ck_psychosocial_enrollments_domains"
    add_check_constraint :psychosocial_enrollments, "esf_covered = (esf_cnes IS NOT NULL)", name: "ck_psychosocial_enrollments_esf"
    add_check_constraint :psychosocial_enrollments,
                         "(closed_on IS NULL) = (destination IS NULL) AND (closed_on IS NULL) = (closed_by_user_id IS NULL) AND " \
                         "(destination IS NULL OR destination::text <> '00'::text)",
                         name: "ck_psychosocial_enrollments_closing"

    create_table :psychosocial_care_plans, id: :uuid do |t|
      t.references :psychosocial_enrollment, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :version, null: false
      # Necessidades e objetivos (JSON): cifrados.
      t.text :needs, null: false
      t.text :goals, null: false
      t.string :intensity, null: false
      t.date :review_on, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :psychosocial_care_plans, %i[psychosocial_enrollment_id version], unique: true, name: "idx_psychosocial_care_plans_version"
    add_check_constraint :psychosocial_care_plans,
                         "version >= 1 AND intensity::text = ANY (ARRAY[#{quoted(INTENSITIES)}]::text[])",
                         name: "ck_psychosocial_care_plans_domains"

    create_table :psychosocial_care_plan_alerts, id: :uuid do |t|
      t.references :psychosocial_care_plan, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :created_at, null: false
    end
    add_index :psychosocial_care_plan_alerts, :psychosocial_care_plan_id, unique: true, name: "idx_psychosocial_care_plan_alerts_plan"
  end

  def create_night_stays
    create_table :psychosocial_night_stays, id: :uuid do |t|
      t.references :psychosocial_bed, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :psychosocial_enrollment, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :started_at, null: false
      t.datetime :expected_end_at, null: false
      t.datetime :ended_at
      # Motivo do fim e da reavaliação acima do limite: cifrados.
      t.text :end_reason
      t.text :reassessment_reason
      t.references :reassessed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.references :started_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.references :closed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :psychosocial_night_stays, :patient_id, unique: true, where: "ended_at IS NULL", name: "idx_psychosocial_night_stays_open_patient"
    add_index :psychosocial_night_stays, %i[health_unit_id started_at], name: "idx_psychosocial_night_stays_unit_started"
    add_index :psychosocial_night_stays, %i[patient_id started_at], name: "idx_psychosocial_night_stays_patient_started"
    add_check_constraint :psychosocial_night_stays,
                         "expected_end_at > started_at AND (ended_at IS NULL OR ended_at > started_at)",
                         name: "ck_psychosocial_night_stays_times"
    add_check_constraint :psychosocial_night_stays,
                         "(ended_at IS NULL) = (end_reason IS NULL) AND (ended_at IS NULL) = (closed_by_user_id IS NULL)",
                         name: "ck_psychosocial_night_stays_closing"
    add_check_constraint :psychosocial_night_stays, "(reassessment_reason IS NULL) = (reassessed_by_user_id IS NULL)",
                         name: "ck_psychosocial_night_stays_reassessment"
    add_exclusion_constraint :psychosocial_night_stays,
                             "psychosocial_bed_id WITH =, tsrange(started_at, COALESCE(ended_at, 'infinity'::timestamp without time zone)) WITH &&",
                             using: :gist, name: "excl_psychosocial_night_stays_bed"
  end

  def create_actions
    create_table :psychosocial_actions, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :sigtap_code, limit: 10, null: false
      t.string :instrument, null: false
      t.datetime :performed_at, null: false
      t.date :month, null: false
      t.string :place, null: false
      t.integer :quantity, null: false, default: 1
      # Evolução e motivo do cancelamento: cifrados.
      t.text :notes
      t.string :authorization_number, limit: 13
      t.references :psychosocial_group, type: :uuid, foreign_key: true, index: false
      t.references :professional_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.string :cbo_code, limit: 6, null: false
      t.string :origin, null: false, default: "manual"
      t.references :psychosocial_night_stay, type: :uuid, foreign_key: true, index: false
      t.datetime :cancelled_at
      t.text :cancel_reason
      t.references :cancelled_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :psychosocial_actions, %i[health_unit_id month], name: "idx_psychosocial_actions_unit_month"
    add_index :psychosocial_actions, %i[health_unit_id performed_at], name: "idx_psychosocial_actions_unit_performed"
    add_index :psychosocial_actions, :psychosocial_night_stay_id, where: "psychosocial_night_stay_id IS NOT NULL",
                                                                  name: "idx_psychosocial_actions_night_stay"
    add_check_constraint :psychosocial_actions,
                         "instrument::text = ANY (ARRAY[#{quoted(INSTRUMENTS)}]::text[]) AND " \
                         "place::text = ANY (ARRAY[#{quoted(PLACES)}]::text[]) AND " \
                         "origin::text = ANY (ARRAY[#{quoted(ACTION_ORIGINS)}]::text[]) AND " \
                         "sigtap_code::text ~ #{SIGTAP} AND cbo_code::text ~ '^[0-9]{6}$'::text AND " \
                         "(authorization_number IS NULL OR authorization_number::text ~ '^[0-9]{13}$'::text) AND " \
                         "quantity >= #{QUANTITY.min} AND quantity <= #{QUANTITY.max}",
                         name: "ck_psychosocial_actions_domains"
    add_check_constraint :psychosocial_actions, FIRST_DAY, name: "ck_psychosocial_actions_month"
    add_check_constraint :psychosocial_actions,
                         "(cancelled_at IS NULL) = (cancel_reason IS NULL) AND (cancelled_at IS NULL) = (cancelled_by_user_id IS NULL)",
                         name: "ck_psychosocial_actions_cancel"

    create_table :psychosocial_action_participants, id: :uuid do |t|
      t.references :psychosocial_action, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :position, limit: 2, null: false
      t.references :psychosocial_enrollment, type: :uuid, foreign_key: true, index: false
      t.references :patient, type: :uuid, foreign_key: true, index: false
      # Nome do familiar (atendimento à família sem cadastro): cifrado.
      t.text :family_name
      t.datetime :created_at, null: false
    end
    add_index :psychosocial_action_participants, %i[psychosocial_action_id position], unique: true,
                                                                                       name: "idx_psychosocial_action_participants_position"
    add_index :psychosocial_action_participants, :psychosocial_enrollment_id, name: "idx_psychosocial_action_participants_enrollment"
    add_index :psychosocial_action_participants, :patient_id, name: "idx_psychosocial_action_participants_patient"
    add_check_constraint :psychosocial_action_participants,
                         "num_nonnulls(patient_id, family_name) = 1 AND (psychosocial_enrollment_id IS NULL OR patient_id IS NOT NULL) AND " \
                         "position >= 1",
                         name: "ck_psychosocial_action_participants_who"
  end

  def create_months
    create_table :psychosocial_month_closures, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.date :month, null: false
      t.references :closed_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :closed_at, null: false
      t.datetime :reopened_at
      t.references :reopened_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      # Motivo da reabertura: cifrado.
      t.text :reopen_reason
      t.datetime :created_at, null: false
    end
    add_index :psychosocial_month_closures, %i[health_unit_id month], unique: true, where: "reopened_at IS NULL",
                                                                      name: "idx_psychosocial_month_closures_active"
    add_check_constraint :psychosocial_month_closures, FIRST_DAY, name: "ck_psychosocial_month_closures_month"
    add_check_constraint :psychosocial_month_closures,
                         "(reopened_at IS NULL) = (reopened_by_user_id IS NULL) AND (reopened_at IS NULL) = (reopen_reason IS NULL)",
                         name: "ck_psychosocial_month_closures_reopen"

    create_table :psychosocial_raas_exports, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.date :month, null: false
      t.string :competence, limit: 6, null: false
      t.references :billing_period, type: :uuid, null: false, foreign_key: true, index: false
      t.string :layout_version, limit: 20, null: false
      # Arquivo da remessa (Base64): cifrado.
      t.text :file_data, null: false
      t.string :sha256, limit: 64, null: false
      t.integer :records_count, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :psychosocial_raas_exports, %i[health_unit_id month], unique: true, name: "idx_psychosocial_raas_exports_month"
    add_check_constraint :psychosocial_raas_exports, FIRST_DAY, name: "ck_psychosocial_raas_exports_month"
    add_check_constraint :psychosocial_raas_exports,
                         "competence::text ~ '^[0-9]{4}(0[1-9]|1[0-2])$'::text AND sha256::text ~ '^[0-9a-f]{64}$'::text AND records_count >= 0",
                         name: "ck_psychosocial_raas_exports_domains"

    create_table :psychosocial_monthly_records, id: :uuid do |t|
      t.references :psychosocial_enrollment, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.date :month, null: false
      t.boolean :homeless
      t.string :destination, limit: 2
      t.date :concluded_on
      t.string :status, null: false, default: "open"
      # Foto do fechamento (JSON): cifrada.
      t.text :snapshot
      t.datetime :closed_at
      t.references :psychosocial_raas_export, type: :uuid, foreign_key: true, index: false
      t.timestamps
    end
    add_index :psychosocial_monthly_records, %i[psychosocial_enrollment_id month], unique: true,
                                                                                   name: "idx_psychosocial_monthly_records_month"
    add_index :psychosocial_monthly_records, %i[health_unit_id month], name: "idx_psychosocial_monthly_records_unit_month"
    add_check_constraint :psychosocial_monthly_records, FIRST_DAY, name: "ck_psychosocial_monthly_records_month"
    add_check_constraint :psychosocial_monthly_records,
                         "status::text = ANY (ARRAY[#{quoted(MONTHLY_STATUSES)}]::text[]) AND " \
                         "(destination IS NULL OR destination::text ~ '^[0-9]{2}$'::text)",
                         name: "ck_psychosocial_monthly_records_domains"
    add_check_constraint :psychosocial_monthly_records, "(status::text = 'open'::text) = (snapshot IS NULL)",
                         name: "ck_psychosocial_monthly_records_snapshot"
  end

  def create_matrix_support
    create_table :psychosocial_matrix_supports, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.references :health_team, type: :uuid, null: false, foreign_key: true, index: false
      t.date :held_on, null: false
      # Tema do encontro: cifrado.
      t.text :topic, null: false
      t.uuid :participant_user_ids, null: false, array: true
      t.string :sigtap_code, limit: 10, null: false
      t.references :psychosocial_action, type: :uuid, null: false, foreign_key: true, index: false
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :psychosocial_matrix_supports, :psychosocial_action_id, unique: true, name: "idx_psychosocial_matrix_supports_action"
    add_index :psychosocial_matrix_supports, %i[health_unit_id held_on], name: "idx_psychosocial_matrix_supports_unit_held"
    add_index :psychosocial_matrix_supports, :health_team_id, name: "idx_psychosocial_matrix_supports_team"
    add_check_constraint :psychosocial_matrix_supports,
                         "cardinality(participant_user_ids) >= 1 AND sigtap_code::text ~ #{SIGTAP}",
                         name: "ck_psychosocial_matrix_supports_domains"

    create_table :psychosocial_matrix_cases, id: :uuid do |t|
      t.references :psychosocial_matrix_support, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      # Texto compartilhado com a UBS: cifrado.
      t.text :shared_text, null: false
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :psychosocial_matrix_cases, :patient_id, name: "idx_psychosocial_matrix_cases_patient"
    add_index :psychosocial_matrix_cases, :psychosocial_matrix_support_id, name: "idx_psychosocial_matrix_cases_support"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
