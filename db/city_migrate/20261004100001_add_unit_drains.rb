# api#29 (F-09.3): esvaziar unidade. Mover um pedido ou um horário para outra
# unidade encerra o antigo como `moved` e cria um novo ligado a ele (as colunas
# de unidade não mudam — triggers). Um pedido não-movido por atendimento; o
# retorno movido sai da própria unidade. E o registro do esvaziamento, com o
# motivo, só acréscimo. Os CHECKs vão na forma que o dump reproduz.
class AddUnitDrains < ActiveRecord::Migration[8.1]
  def up
    add_reference :appointment_requests, :moved_from_request, type: :uuid,
                  foreign_key: { to_table: :appointment_requests }, index: { unique: true }
    remove_index :appointment_requests, name: "index_appointment_requests_on_origin_attendance_id"
    add_index :appointment_requests, :origin_attendance_id, unique: true,
              where: "((closed_reason)::text IS DISTINCT FROM 'moved'::text)",
              name: "index_appointment_requests_on_origin_attendance_id"
    replace_check :appointment_requests, "ck_appointment_requests_closed_reason",
                  "closed_reason IS NULL OR closed_reason::text = ANY (ARRAY['fulfilled', 'citizen_cancelled', " \
                  "'dismissed', 'moved']::text[])"
    replace_check :appointment_requests, "ck_appointment_requests_return_same_unit",
                  "kind::text <> 'return'::text OR origin_unit_id = target_unit_id OR moved_from_request_id IS NOT NULL"

    add_reference :appointments, :moved_from_appointment, type: :uuid,
                  foreign_key: { to_table: :appointments }, index: { unique: true }
    replace_check :appointments, "ck_appointments_status",
                  "status::text = ANY (ARRAY['scheduled', 'confirmed', 'checked_in', 'cancelled_by_citizen', " \
                  "'expired', 'no_show', 'moved']::text[])"

    create_table :health_unit_drains, id: :uuid do |t|
      t.references :health_unit, type: :uuid, null: false, foreign_key: true
      t.references :target_unit, type: :uuid, null: false, foreign_key: { to_table: :health_units }
      t.text :reason, null: false
      t.references :drained_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.integer :requests_count, null: false
      t.integer :appointments_count, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :health_unit_drains, "length(btrim(reason)) >= 10", name: "ck_health_unit_drains_reason"

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    drop_table :health_unit_drains
    replace_check :appointments, "ck_appointments_status",
                  "status::text = ANY (ARRAY['scheduled', 'confirmed', 'checked_in', 'cancelled_by_citizen', " \
                  "'expired', 'no_show']::text[])"
    remove_reference :appointments, :moved_from_appointment
    replace_check :appointment_requests, "ck_appointment_requests_return_same_unit",
                  "kind::text <> 'return'::text OR origin_unit_id = target_unit_id"
    replace_check :appointment_requests, "ck_appointment_requests_closed_reason",
                  "closed_reason IS NULL OR closed_reason::text = ANY (ARRAY['fulfilled', 'citizen_cancelled', " \
                  "'dismissed']::text[])"
    remove_index :appointment_requests, name: "index_appointment_requests_on_origin_attendance_id"
    add_index :appointment_requests, :origin_attendance_id, unique: true,
              name: "index_appointment_requests_on_origin_attendance_id"
    remove_reference :appointment_requests, :moved_from_request
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  private

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
