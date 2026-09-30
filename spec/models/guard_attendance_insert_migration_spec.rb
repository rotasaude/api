require "rails_helper"
require Rails.root.join("db/city_migrate/20260930100001_guard_attendance_insert.rb").to_s

# Critério de fechamento do módulo 13: o down() da migração de cidade
# 20260930100001 tira só o trigger e a função do nascimento waiting, e o up()
# seguinte restaura o schema idêntico. Mesmo desenho de
# create_campaigns_migration_spec.rb: down e up num savepoint desfeito no fim,
# e o retrato lido pela mesma conexão.
RSpec.describe "Migração de cidade 20260930100001 (GuardAttendanceInsert): down e up" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  def conn = ApplicationRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { GuardAttendanceInsert.new.exec_migration(conn, direction) }
  end

  def fingerprint
    {
      triggers: conn.select_rows(<<~SQL),
        SELECT c.relname, t.tgname, pg_get_triggerdef(t.oid)
        FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND NOT t.tgisinternal ORDER BY 1, 2
      SQL
      functions: conn.select_rows(<<~SQL)
        SELECT p.proname, pg_get_functiondef(p.oid)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.prokind = 'f' ORDER BY 1, 2
      SQL
    }
  end

  let(:unit) { create_unit }
  let(:user) { staff_with("migracao@cidade.gov.br") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  def insert_in_care
    triage = completed_web_triage_for(citizen)
    Attendance.insert_all!([ { triage_id: triage.id, citizen_id: citizen.id, health_unit_id: unit.id,
                               checked_in_by_user_id: user.id, checked_in_at: Time.current, check_in_method: "code",
                               status: "in_care", called_by_user_id: user.id, called_at: Time.current,
                               created_at: Time.current } ])
  end

  it "down tira só o trigger e a função; up seguinte restaura o schema idêntico e volta a recusar" do
    ApplicationRecord.transaction(requires_new: true) do
      before = fingerprint
      expect(before[:triggers].map(&:second)).to include("attendances_born_waiting")
      expect(before[:functions].map(&:first)).to include("rota_attendance_insert_guard")

      migrate(:down)
      down = fingerprint
      expect(down[:triggers].map(&:second)).not_to include("attendances_born_waiting")
      expect(down[:functions].map(&:first)).not_to include("rota_attendance_insert_guard")
      untouched = ->(fp) { fp.transform_values { |rows| rows.reject { |r| r.join(" ").include?("attendance_insert_guard") || r.second == "attendances_born_waiting" } } }
      expect(untouched.call(down)).to eq(untouched.call(before))
      expect { ApplicationRecord.transaction(requires_new: true) { insert_in_care } }.not_to raise_error

      migrate(:up)
      expect(fingerprint).to eq(before)
      expect { ApplicationRecord.transaction(requires_new: true) { insert_in_care } }
        .to raise_error(ActiveRecord::StatementInvalid, /born waiting/)
      raise ActiveRecord::Rollback
    end
  end
end
