# O fuso da cidade é definido no provisionamento e não muda (api#36; decisão
# do usuário). Só trigger: vem de db/platform_triggers.sql, como
# 20260927300002 — o arquivo é idempotente e reinstala os demais sem mudança.
class CitiesTimeZoneImmutable < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/platform_triggers.sql"))
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS cities_time_zone_immutable ON cities;
      DROP FUNCTION IF EXISTS cities_time_zone_immutable();
    SQL
  end
end
