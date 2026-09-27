# domain_events só acréscimo: publicação marcada uma vez, DELETE só além da
# retenção de 12 meses (ADR-0014; F-07.1, fechamento do módulo 07). Só trigger,
# sem mudança de tabela: vem de db/city_triggers.sql, como GuardUsersAndMemberships.
class GuardDomainEvents < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS domain_events_guard ON domain_events"
    execute "DROP FUNCTION IF EXISTS rota_domain_event_guard()"
  end
end
