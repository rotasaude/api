require "rails_helper"
require Rails.root.join("db/platform_migrate/20261002300001_normalize_city_analytics_indicator_check.rb").to_s

# api#38: a migração troca a regra de indicador pela forma estável; o down volta
# à forma antiga (IN) e o up seguinte devolve exatamente a regra de antes.
RSpec.describe "Migração de plataforma 20261002300001 (NormalizeCityAnalyticsIndicatorCheck): down e up" do
  def conn = PlatformRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { NormalizeCityAnalyticsIndicatorCheck.new.exec_migration(conn, direction) }
  end

  def indicator_check
    conn.select_value(<<~SQL)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conname = 'ck_city_analytics_indicators_indicator'
    SQL
  end

  it "down volta à forma IN; up seguinte restaura a regra estável idêntica" do
    PlatformRecord.transaction(requires_new: true) do
      before = indicator_check
      expect(before).to include("'triages_started'::text")

      migrate(:down)
      expect(indicator_check).to include("'triages_started'::character varying")

      migrate(:up)
      expect(indicator_check).to eq(before)
      raise ActiveRecord::Rollback
    end
  end
end
