# Agenda dos profissionais (ADR 0029; spec 2026-10-05 §3–§5): tipos de
# atendimento (base copiada), modelos de agenda, colunas novas em horários,
# pedidos, turnos, vínculos e perfil da cidade; ligação pedido↔triagem; avisos
# de lembrete; e a trava de sobreposição dos horários `slot` (btree_gist).
# Todo horário existente vira `legacy` (padrão da coluna, sem UPDATE); a
# verificação de sobreposição herdada roda antes da EXCLUDE e aborta listando
# os pares. CHECKs na forma que o dump reproduz.
class AddProfessionalSchedules < ActiveRecord::Migration[8.1]
  class InheritedOverlap < StandardError; end

  ACTIVE = "status::text = ANY (ARRAY['scheduled', 'confirmed', 'checked_in']::text[])".freeze
  BASE_PATH = Rails.root.join("config/scheduling/appointment_types.yml")

  # Pares (a < b) de horários `slot` ativos do mesmo profissional que se
  # sobrepõem: exatamente o que a EXCLUDE recusaria.
  def self.inherited_overlaps(connection)
    connection.select_rows(<<~SQL)
      SELECT a.id, b.id FROM appointments a
      JOIN appointments b ON b.professional_id = a.professional_id AND a.id < b.id
       AND tsrange(a.scheduled_at, a.ends_at) && tsrange(b.scheduled_at, b.ends_at)
      WHERE a.booking_kind = 'slot' AND b.booking_kind = 'slot'
        AND a.status IN ('scheduled', 'confirmed', 'checked_in') AND b.status IN ('scheduled', 'confirmed', 'checked_in')
      ORDER BY 1, 2
    SQL
  end

  def self.assert_no_inherited_overlap!(connection)
    pairs = inherited_overlaps(connection)
    return if pairs.empty?

    raise InheritedOverlap, "horários sobrepostos herdados — decida cada par antes de migrar: " +
                            pairs.map { |a, b| "#{a} × #{b}" }.join("; ")
  end

  def up
    enable_extension "btree_gist" unless extension_enabled?("btree_gist")

    create_table :appointment_types, id: :uuid do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.integer :duration_minutes, null: false
      t.string :cbo_prefixes, array: true, null: false, default: []
      t.boolean :active, null: false, default: true
      t.string :origin, null: false
      t.integer :position, null: false, default: 100
      t.timestamps
    end
    add_index :appointment_types, :key, unique: true
    add_check_constraint :appointment_types, "key::text ~ '^[a-z][a-z0-9_]{1,40}$'::text", name: "ck_appointment_types_key"
    add_check_constraint :appointment_types, "duration_minutes >= 5 AND duration_minutes <= 240",
                         name: "ck_appointment_types_duration"
    add_check_constraint :appointment_types, "origin::text = ANY (ARRAY['platform', 'city']::text[])",
                         name: "ck_appointment_types_origin"
    add_check_constraint :appointment_types, "cardinality(cbo_prefixes) >= 1 AND cardinality(cbo_prefixes) <= 20",
                         name: "ck_appointment_types_cbo_prefixes"
    copy_base_types

    create_table :schedule_templates, id: :uuid do |t|
      t.string :name, null: false
      t.integer :fit_in_limit, null: false, default: 2
      t.jsonb :blocks, null: false, default: []
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_check_constraint :schedule_templates, "fit_in_limit >= 0 AND fit_in_limit <= 20",
                         name: "ck_schedule_templates_fit_in_limit"
    add_check_constraint :schedule_templates, "jsonb_typeof(blocks) = 'array'::text", name: "ck_schedule_templates_blocks"

    add_reference :professional_shifts, :schedule_template, type: :uuid, foreign_key: true, index: true
    add_column :professional_links, :default_appointment_type_key, :string
    add_column :city_profile, :default_fit_in_limit, :integer, null: false, default: 2
    add_check_constraint :city_profile, "default_fit_in_limit >= 0 AND default_fit_in_limit <= 20",
                         name: "ck_city_profile_default_fit_in_limit"

    change_requests
    change_appointments

    create_table :appointment_request_triages, id: :uuid do |t|
      t.references :request, type: :uuid, null: false, foreign_key: { to_table: :appointment_requests }, index: false
      t.references :triage, type: :uuid, null: false, foreign_key: true, index: true
      t.datetime :created_at, null: false
    end
    add_index :appointment_request_triages, %i[request_id triage_id], unique: true,
              name: "idx_appointment_request_triages_pair"

    create_table :appointment_notices, id: :uuid do |t|
      t.references :appointment, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: true
      t.datetime :read_at
      t.datetime :created_at, null: false
    end

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  # Pedidos e horários só aceitam acréscimo, e os guardas de db/city_triggers.sql
  # passam a citar as colunas novas.
  def down
    raise ActiveRecord::IrreversibleMigration, "horários e pedidos só aceitam acréscimo; os guardas dependem destas colunas"
  end

  private

  def change_requests
    # O guarda recusa UPDATE em pedido encerrado; o backfill de due_on passa por
    # todos. O city_triggers.sql do fim recria o trigger.
    execute "DROP TRIGGER IF EXISTS appointment_requests_guard ON appointment_requests"

    add_reference :appointment_requests, :origin_triage, type: :uuid, foreign_key: { to_table: :triages }, index: true
    change_column_null :appointment_requests, :origin_attendance_id, true
    change_column_null :appointment_requests, :origin_unit_id, true
    change_column_null :appointment_requests, :target_unit_id, true
    add_column :appointment_requests, :appointment_type_key, :string, null: false, default: "retorno"
    add_column :appointment_requests, :priority, :string, null: false, default: "routine"
    add_column :appointment_requests, :due_on, :date
    execute "UPDATE appointment_requests SET due_on = (created_at::date + 30)"
    change_column_null :appointment_requests, :due_on, false
    add_column :appointment_requests, :reschedule_reason_code, :string
    add_column :appointment_requests, :reschedule_note, :text
    add_column :appointment_requests, :preferred_period, :string
    add_column :appointment_requests, :reschedule_count, :integer, null: false, default: 0

    replace_check :appointment_requests, "ck_appointment_requests_kind",
                  "kind::text = ANY (ARRAY['return', 'referral', 'triage']::text[])"
    replace_check :appointment_requests, "ck_appointment_requests_closed_reason",
                  "closed_reason IS NULL OR closed_reason::text = ANY (ARRAY['fulfilled', 'citizen_cancelled', " \
                  "'dismissed', 'moved', 'consent_revoked']::text[])"
    replace_check :appointment_requests, "ck_appointment_requests_reopened_reason",
                  "reopened_reason IS NULL OR reopened_reason::text = ANY (ARRAY['expired', 'no_show', " \
                  "'citizen_reschedule']::text[])"
    add_check_constraint :appointment_requests, "(origin_attendance_id IS NULL) <> (origin_triage_id IS NULL)",
                         name: "ck_appointment_requests_origin"
    add_check_constraint :appointment_requests, "(kind::text = 'triage'::text) = (origin_triage_id IS NOT NULL)",
                         name: "ck_appointment_requests_triage_kind"
    add_check_constraint :appointment_requests,
                         "origin_attendance_id IS NULL OR (origin_unit_id IS NOT NULL AND target_unit_id IS NOT NULL)",
                         name: "ck_appointment_requests_attendance_units"
    add_check_constraint :appointment_requests, "priority::text = ANY (ARRAY['routine', 'priority']::text[])",
                         name: "ck_appointment_requests_priority"
    add_check_constraint :appointment_requests,
                         "preferred_period IS NULL OR preferred_period::text = ANY (ARRAY['morning', 'afternoon', 'any']::text[])",
                         name: "ck_appointment_requests_preferred_period"
    add_check_constraint :appointment_requests,
                         "reschedule_reason_code IS NULL OR reschedule_reason_code::text = ANY " \
                         "(ARRAY['work', 'health', 'transport', 'other']::text[])",
                         name: "ck_appointment_requests_reschedule_reason_code"
    add_check_constraint :appointment_requests, "reschedule_note IS NULL OR length(reschedule_note) <= 200",
                         name: "ck_appointment_requests_reschedule_note"
    add_check_constraint :appointment_requests, "reschedule_count >= 0", name: "ck_appointment_requests_reschedule_count"
    # Um pedido de triagem vivo (aberto ou agendado) por tipo por cidadão: assim
    # reabrir o agendado (lapso, remarcação) nunca colide com outro aberto.
    add_index :appointment_requests, %i[citizen_id appointment_type_key], unique: true,
              where: "kind::text = 'triage'::text AND status::text = ANY (ARRAY['open', 'scheduled']::text[])",
              name: "idx_appointment_requests_one_live_triage_type"
    add_index :appointment_requests, %i[target_unit_id status due_on], name: "idx_appointment_requests_queue"
  end

  def change_appointments
    add_reference :appointments, :professional, type: :uuid, foreign_key: true, index: false
    add_column :appointments, :appointment_type_key, :string
    add_column :appointments, :ends_at, :datetime
    add_reference :appointments, :shift, type: :uuid, foreign_key: { to_table: :professional_shifts }, index: true
    add_column :appointments, :booking_kind, :string, null: false, default: "legacy"
    add_column :appointments, :fit_in_reason, :text
    add_column :appointments, :reschedule_requested, :boolean, null: false, default: false
    add_column :appointments, :reminded_at, :datetime
    add_index :appointments, %i[professional_id scheduled_at], name: "idx_appointments_professional_time"
    add_index :appointments, %i[citizen_id scheduled_at], name: "idx_appointments_citizen_time"
    add_check_constraint :appointments, "booking_kind::text = ANY (ARRAY['slot', 'fit_in', 'legacy']::text[])",
                         name: "ck_appointments_booking_kind"
    add_check_constraint :appointments,
                         "booking_kind::text = 'legacy'::text OR (professional_id IS NOT NULL AND " \
                         "appointment_type_key IS NOT NULL AND ends_at IS NOT NULL AND shift_id IS NOT NULL)",
                         name: "ck_appointments_booking_fields"
    add_check_constraint :appointments, "ends_at IS NULL OR ends_at > scheduled_at", name: "ck_appointments_ends"
    add_check_constraint :appointments,
                         "((booking_kind::text = 'fit_in'::text) = (fit_in_reason IS NOT NULL)) AND " \
                         "(fit_in_reason IS NULL OR length(btrim(fit_in_reason)) >= 10)",
                         name: "ck_appointments_fit_in_reason"

    self.class.assert_no_inherited_overlap!(connection)
    add_exclusion_constraint :appointments, "professional_id WITH =, tsrange(scheduled_at, ends_at) WITH &&",
                             using: :gist, where: "booking_kind::text = 'slot'::text AND #{ACTIVE}",
                             name: "excl_appointments_slot_overlap"
  end

  # Só insere o que falta (ON CONFLICT): rodar de novo não desfaz ajuste da cidade.
  def copy_base_types
    YAML.load_file(BASE_PATH).each_with_index do |type, index|
      prefixes = type.fetch("cbo_prefixes").map { |p| connection.quote(p.to_s) }.join(", ")
      execute <<~SQL
        INSERT INTO appointment_types (key, name, duration_minutes, cbo_prefixes, active, origin, position, created_at, updated_at)
        VALUES (#{connection.quote(type.fetch('key'))}, #{connection.quote(type.fetch('name'))},
                #{Integer(type.fetch('duration_minutes'))}, ARRAY[#{prefixes}]::varchar[], true, 'platform', #{index + 1},
                now(), now())
        ON CONFLICT (key) DO NOTHING
      SQL
    end
  end

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
