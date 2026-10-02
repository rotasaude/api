# api#39: lembrete de confirmação do horário (ADR 0019, Revisão 2026-10-02).
# Um registro por horário, só acréscimo (trigger em city_triggers.sql): é a
# prova de que o lembrete foi tentado e com que resultado. E o opt-out de
# lembretes do cidadão, separado do opt-in das campanhas.
class CreateAppointmentReminders < ActiveRecord::Migration[8.1]
  def up
    create_table :appointment_reminders, id: :uuid do |t|
      t.references :appointment, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :status, null: false
      t.string :error
      t.datetime :created_at, null: false
    end
    add_check_constraint :appointment_reminders,
                         "status IN ('sent','failed','unavailable','disabled','opted_out')",
                         name: "ck_appointment_reminders_status"

    add_column :citizen_contact_preferences, :appointment_reminders_muted, :boolean, null: false, default: false

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    remove_column :citizen_contact_preferences, :appointment_reminders_muted
    drop_table :appointment_reminders
  end
end
