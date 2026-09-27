# Toda a trilha de plataforma imutável: só published_at muda; DELETE nunca para
# maintenance.%, e só além de 12 meses para o resto (ADR-0014/0020; F-07.11,
# fechamento do módulo 07). Só trigger: vem de db/platform_triggers.sql.
class PlatformEventsImmutable < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/platform_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS platform_events_immutable ON platform_events"
    execute "DROP FUNCTION IF EXISTS platform_events_immutable()"
  end
end
