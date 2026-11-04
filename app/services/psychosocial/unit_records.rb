# O que prende uma unidade ao kind `caps` (ADR 0049; fix round 1 da Task 3):
# qualquer linha de uma tabela psychosocial_* com health_unit_id (leitos,
# grupos, encaminhamentos, acolhimentos, matrículas, ações, permanências,
# RAAS, fechamentos, remessas, matriciamento). As tabelas vêm do esquema da
# cidade (cache do schema da conexão), então uma tabela nova do CAPS com
# health_unit_id entra sozinha; as que só apontam para a matrícula ou a ação
# já são cobertas pela linha-mãe.
module Psychosocial
  module UnitRecords
    PREFIX = "psychosocial_".freeze

    module_function

    def tables
      connection = ApplicationRecord.connection
      connection.tables.select do |table|
        table.start_with?(PREFIX) && connection.schema_cache.columns_hash(table).key?("health_unit_id")
      end.sort
    end

    # -> true quando o CAPS tem ao menos um registro do CAPS (uma consulta só).
    def any?(health_unit_id)
      connection = ApplicationRecord.connection
      id = connection.quote(health_unit_id)
      checks = tables.map { |table| "EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)} WHERE health_unit_id = #{id})" }
      return false if checks.empty?

      connection.select_value("SELECT #{checks.join(' OR ')}") == true
    end
  end
end
