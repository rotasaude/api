# Versão de protocolo imutável depois de publicada e nunca apagada (ADR 0009;
# verificação do módulo 03). Só trigger, sem mudança de tabela: o dump
# db/city_schema.rb não o representa, então ele vem de db/city_triggers.sql —
# a mesma fonte que load_city_schema executa depois de carregar o dump (bancos
# de teste e dev) e que esta migração executa nos bancos de cidade já
# existentes (rollout: city:migrate:all).
class GuardProtocolDefinitions < ActiveRecord::Migration[8.1]
  def up
    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    execute "DROP TRIGGER IF EXISTS protocol_definitions_guard ON protocol_definitions"
    execute "DROP TRIGGER IF EXISTS protocol_definitions_append_only_truncate ON protocol_definitions"
    execute "DROP FUNCTION IF EXISTS rota_protocol_definition_guard()"
  end
end
