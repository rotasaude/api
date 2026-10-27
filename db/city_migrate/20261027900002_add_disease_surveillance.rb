# Módulo 25 (ADR 0043): vigilância epidemiológica. Papel surveillance; unidade
# notificadora; doenças locais (a lista nacional mora na plataforma);
# notificações com a ficha cifrada; andamento (só acréscimo, motivo cifrado)
# e negativa semanal (só acréscimo). Triggers em db/city_triggers.sql.
# Irreversível.
class AddDiseaseSurveillance < ActiveRecord::Migration[8.1]
  ROLES = %w[analyst billing_clerk campaign_manager citizen_verifier exam_provider exam_regulator health_professional lab_releaser
             lab_staff municipal_admin protocol_author protocol_publisher protocol_reviewer surveillance viewer].freeze
  DEADLINES = %w[immediate weekly].freeze
  ORIGINS = %w[consultation manual safety_net].freeze
  STATUSES = %w[possible notified investigating closed entered dismissed].freeze
  CLASSIFICATIONS = %w[confirmed discarded inconclusive].freeze

  def up
    replace_check :memberships, "ck_memberships_role", "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])"

    # R7: a unidade da atenção primária (ativa) notifica por padrão; as outras
    # o vigilante liga à mão.
    add_column :health_units, :notifying, :boolean, null: false, default: false
    execute "UPDATE health_units SET notifying = true WHERE kind = 'ubs' AND active"

    create_table :local_notifiable_diseases, id: :uuid do |t|
      t.string :code, limit: 46, null: false
      t.string :name, limit: 120, null: false
      t.string :deadline, null: false
      t.jsonb :cid10, null: false, default: []
      t.jsonb :ciap2, null: false, default: []
      t.integer :repeat_after_days, null: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :local_notifiable_diseases, :code, unique: true, name: "idx_local_notifiable_diseases_code"
    add_check_constraint :local_notifiable_diseases, "code::text ~ '^local_[a-z0-9_]{1,40}$'::text", name: "ck_local_notifiable_diseases_code"
    add_check_constraint :local_notifiable_diseases, "deadline::text = ANY (ARRAY[#{quoted(DEADLINES)}]::text[])",
                         name: "ck_local_notifiable_diseases_deadline"
    add_check_constraint :local_notifiable_diseases, "repeat_after_days >= 1 AND repeat_after_days <= 36500",
                         name: "ck_local_notifiable_diseases_repeat"

    create_table :disease_notifications, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: true
      t.string :disease_code, limit: 48, null: false
      t.integer :disease_list_version
      t.string :deadline, null: false
      t.string :origin, null: false
      t.string :status, null: false
      t.string :classification
      t.date :suspected_on, null: false
      t.date :symptoms_on
      t.datetime :due_at, null: false
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :unit_cnes, limit: 7
      t.references :notifier_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.references :consultation, type: :uuid, foreign_key: true, index: true
      t.references :addendum, type: :uuid, foreign_key: { to_table: :consultation_addenda }, index: false
      t.text :form, null: false
      t.string :official_number, limit: 30
      t.boolean :resident_elsewhere, null: false, default: false
      t.string :residence_ibge, limit: 7
      t.references :neighborhood, type: :uuid, foreign_key: true, index: false
      t.datetime :closed_at
      t.datetime :entered_at
      t.datetime :dismissed_at
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :disease_notifications, %i[patient_id disease_code], unique: true,
                                                                   where: "status::text IN ('possible', 'notified', 'investigating')",
                                                                   name: "idx_disease_notifications_one_open"
    add_index :disease_notifications, %i[status due_at], name: "idx_disease_notifications_status_due"
    add_index :disease_notifications, %i[health_unit_id suspected_on], name: "idx_disease_notifications_unit_suspected"
    add_index :disease_notifications, :suspected_on, name: "idx_disease_notifications_suspected_on"
    add_check_constraint :disease_notifications, "deadline::text = ANY (ARRAY[#{quoted(DEADLINES)}]::text[])",
                         name: "ck_disease_notifications_deadline"
    add_check_constraint :disease_notifications, "origin::text = ANY (ARRAY[#{quoted(ORIGINS)}]::text[])",
                         name: "ck_disease_notifications_origin"
    add_check_constraint :disease_notifications, "status::text = ANY (ARRAY[#{quoted(STATUSES)}]::text[])",
                         name: "ck_disease_notifications_status"
    add_check_constraint :disease_notifications,
                         "(classification IS NULL OR classification::text = ANY (ARRAY[#{quoted(CLASSIFICATIONS)}]::text[])) " \
                         "AND ((classification IS NOT NULL) = (status::text = ANY (ARRAY['closed'::text, 'entered'::text])))",
                         name: "ck_disease_notifications_classification"
    add_check_constraint :disease_notifications, "symptoms_on IS NULL OR symptoms_on <= suspected_on",
                         name: "ck_disease_notifications_symptoms_on"
    add_check_constraint :disease_notifications, "(official_number IS NOT NULL) = (status::text = 'entered'::text)",
                         name: "ck_disease_notifications_official_number"
    add_check_constraint :disease_notifications,
                         "resident_elsewhere = (residence_ibge IS NOT NULL) AND (residence_ibge IS NULL OR residence_ibge::text ~ '^[0-9]{7}$'::text)",
                         name: "ck_disease_notifications_residence"
    add_check_constraint :disease_notifications, "version >= 1", name: "ck_disease_notifications_version"

    create_table :disease_notification_events, id: :uuid do |t|
      t.references :notification, type: :uuid, null: false, foreign_key: { to_table: :disease_notifications }, index: true
      t.string :status, null: false
      t.string :classification
      t.references :by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :reason
      t.datetime :created_at, null: false
    end
    add_check_constraint :disease_notification_events, "status::text = ANY (ARRAY[#{quoted(STATUSES)}]::text[])",
                         name: "ck_disease_notification_events_status"
    add_check_constraint :disease_notification_events,
                         "classification IS NULL OR classification::text = ANY (ARRAY[#{quoted(CLASSIFICATIONS)}]::text[])",
                         name: "ck_disease_notification_events_classification"

    create_table :weekly_negative_reports, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true, index: false
      t.string :week, limit: 7, null: false
      t.references :recorded_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :weekly_negative_reports, %i[health_unit_id week], unique: true, name: "idx_weekly_negative_reports_unit_week"
    add_check_constraint :weekly_negative_reports, "week::text ~ '^[0-9]{4}-[0-9]{2}$'::text", name: "ck_weekly_negative_reports_week"

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
