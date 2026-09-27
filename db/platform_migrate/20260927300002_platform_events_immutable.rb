# Toda a trilha de plataforma imutável: só published_at muda; DELETE nunca para
# maintenance.%, e só além de 12 meses para o resto (ADR-0014/0020; F-07.11,
# fechamento do módulo 07). Só trigger: vem de db/platform_triggers.sql.
class PlatformEventsImmutable < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/platform_triggers.sql"))
  end

  # Desfazer deixaria a auditoria de manutenção sem proteção nenhuma: o trigger
  # antigo (só maintenance.%) saiu do db/platform_triggers.sql junto.
  def down
    raise ActiveRecord::IrreversibleMigration, "platform_events ficaria sem trigger de imutabilidade"
  end
end
