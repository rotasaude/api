# Consentimento imutável (ADR 0008; verificação do módulo 02). Só trigger, sem
# mudança de tabela: o dump db/city_schema.rb não o representa, então ele vem
# de db/city_triggers.sql — a mesma fonte que load_city_schema executa depois
# de carregar o dump (bancos de teste e dev) e que esta migração executa nos
# bancos de cidade já existentes (rollout: city:migrate:all).
class GuardConsents < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS consents_guard ON consents"
    execute "DROP TRIGGER IF EXISTS consents_append_only_truncate ON consents"
    execute "DROP FUNCTION IF EXISTS rota_consent_guard()"
  end
end
