# Termo de consentimento append-only (ADR-0013; F-06.13, fechamento do módulo
# 06). Só trigger, sem mudança de tabela: o dump db/city_schema.rb não o
# representa, então ele vem de db/city_triggers.sql — a mesma fonte que
# load_city_schema executa depois de carregar o dump (bancos de teste e dev) e
# que esta migração executa nos bancos de cidade já existentes (rollout:
# city:migrate:all).
class GuardConsentTerms < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS consent_terms_append_only ON consent_terms"
  end
end
