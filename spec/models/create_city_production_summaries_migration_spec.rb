require "rails_helper"
require Rails.root.join("db/platform_migrate/20261006200002_create_city_production_summaries.rb").to_s

RSpec.describe "Migração de plataforma 20261006200002 (CreateCityProductionSummaries): down e up" do
  def conn = PlatformRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { CreateCityProductionSummaries.new.exec_migration(conn, direction) }
    CityProductionSummary.reset_column_information
  end

  def fingerprint
    {
      columns: conn.select_rows("SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns " \
                                "WHERE table_name = 'city_production_summaries' ORDER BY 1"),
      indexes: conn.select_rows("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'city_production_summaries' ORDER BY 1")
    }
  end

  it "down remove a tabela; up seguinte restaura idêntica" do
    PlatformRecord.transaction(requires_new: true) do
      before = fingerprint
      migrate(:down)
      expect(conn.table_exists?(:city_production_summaries)).to be(false)
      migrate(:up)
      expect(fingerprint).to eq(before)
      raise ActiveRecord::Rollback
    end
  ensure
    CityProductionSummary.reset_column_information
  end
end
