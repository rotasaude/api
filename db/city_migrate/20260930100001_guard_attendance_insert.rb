# attendances nasce waiting, sem chamada nem desfecho (critério de fechamento do
# módulo 13; ADR 0018). Só trigger, sem mudança de tabela: vem de
# db/city_triggers.sql, como GuardDomainEvents.
class GuardAttendanceInsert < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS attendances_born_waiting ON attendances"
    execute "DROP FUNCTION IF EXISTS rota_attendance_insert_guard()"
  end
end
