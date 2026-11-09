# Módulo 32a (ADR 0050; contrato §1 e §14 Q7/Q9; plano, Desvios 1–3 e Valores
# fixados 4 e 5): o atendimento do 13 ganha a origem explícita
# (`origin_kind`: triage, appointment, walk_in). O `walk_in` é a chegada na
# UPA: sem triagem, sem horário e sem o par do wpda — a pessoa é o Patient
# (`patient_id`), e o check-in é `urgency_reception`. A senha da sala de
# espera (`ticket`) conta por unidade e dia local (`ticket_on`). A unidade
# ganha o prefixo da senha e o flag dos tempos na TV (UPA: U/true).
# O backfill da origem passa por linhas encerradas, que o
# rota_attendance_guard recusa: o trigger sai antes e o city_triggers.sql do
# fim o recria (com origem, paciente e senha na lista do que nunca muda).
# Irreversível.
class AddUrgencyAttendanceOrigin < ActiveRecord::Migration[8.1]
  METHODS = %w[code cpf_exception urgency_reception].freeze

  def up
    change_attendances
    change_health_units
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def change_attendances
    execute "DROP TRIGGER IF EXISTS attendances_guard ON attendances"

    add_column :attendances, :origin_kind, :string
    add_reference :attendances, :patient, type: :uuid, foreign_key: true, index: true
    add_column :attendances, :ticket, :string, limit: 8
    add_column :attendances, :ticket_on, :date
    change_column_null :attendances, :citizen_id, true
    execute "UPDATE attendances SET origin_kind = CASE WHEN triage_id IS NOT NULL THEN 'triage' ELSE 'appointment' END"

    replace_check :attendances, "ck_attendances_origin",
                  "origin_kind IS NOT NULL AND (" \
                  "(origin_kind::text = 'triage'::text AND triage_id IS NOT NULL AND appointment_id IS NULL) " \
                  "OR (origin_kind::text = 'appointment'::text AND appointment_id IS NOT NULL AND triage_id IS NULL) " \
                  "OR (origin_kind::text = 'walk_in'::text AND triage_id IS NULL AND appointment_id IS NULL " \
                  "AND patient_id IS NOT NULL AND citizen_id IS NULL))"
    add_check_constraint :attendances, "origin_kind::text = 'walk_in'::text OR citizen_id IS NOT NULL",
                         name: "ck_attendances_citizen"
    replace_check :attendances, "ck_attendances_method", "check_in_method::text = ANY (ARRAY[#{quoted(METHODS)}]::text[])"
    replace_check :attendances, "ck_attendances_exception_reason",
                  "(check_in_method::text = 'code'::text AND exception_reason IS NULL) " \
                  "OR (check_in_method::text = 'cpf_exception'::text AND exception_reason IS NOT NULL " \
                  "AND length(btrim(exception_reason)) >= 10) " \
                  "OR (check_in_method::text = 'urgency_reception'::text AND exception_reason IS NULL)"
    add_check_constraint :attendances, "(origin_kind::text = 'walk_in'::text) = (check_in_method::text = 'urgency_reception'::text)",
                         name: "ck_attendances_walk_in_method"
    add_check_constraint :attendances,
                         "(ticket IS NULL) = (ticket_on IS NULL) AND (ticket IS NULL OR ticket::text ~ '^[A-Z]{1,3}-[0-9]{3,4}$'::text)",
                         name: "ck_attendances_ticket"
    add_index :attendances, %i[health_unit_id ticket_on ticket], unique: true, where: "ticket IS NOT NULL",
                                                                 name: "idx_attendances_ticket"
    add_index :attendances, %i[patient_id health_unit_id], unique: true,
                                                         where: "origin_kind::text = 'walk_in'::text AND status::text <> 'closed'::text",
                                                         name: "idx_attendances_open_walk_in"
  end

  def change_health_units
    add_column :health_units, :ticket_prefix, :string, limit: 3, null: false, default: "A"
    add_column :health_units, :show_wait_times, :boolean, null: false, default: false
    add_check_constraint :health_units, "ticket_prefix::text ~ '^[A-Z]{1,3}$'::text", name: "ck_health_units_ticket_prefix"
    execute "UPDATE health_units SET ticket_prefix = 'U', show_wait_times = true WHERE kind = 'upa'"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
