# Edição dos parâmetros técnicos pela coordenação (módulo 35a, ADR 0054;
# contrato §11, §12; A-4, A-5, Q17). Só a coordenação, com step-up (quem chama
# confere). `values` traz as 20 chaves do defaults.yml, nenhuma a mais nem a
# menos (VectorControl::Parameters.validate); recusa → invalid_parameter com o
# path `values.<chave>` (`values` quando não é objeto), só o primeiro erro.
#
# Cada edição cria a versão seguinte (vector_parameter_versions é só
# acréscimo, por trigger): sem linha, a vigente é a 0 (o defaults.yml) e a
# primeira edição grava a 1. Um advisory lock da transação serializa dois PUTs
# antes de ler a maior versão; o índice único em `version` é o cinto.
# `vector_parameters.changed` com `version` e `user_id` (§17).
module VectorControl
  module SaveParameters
    LOCK = "vector_parameter_versions".freeze
    EVENT = "vector_parameters.changed".freeze

    module_function

    # -> Result.ok(version: VectorParameterVersion) | fail(:invalid_parameter, details: { path: })
    def call(values:, by:)
      refusal = Parameters.validate(values)
      return Result.fail(:invalid_parameter, details: { path: [ "values", refusal[:path] ].compact.join(".") }) if refusal

      normalized = Parameters.normalize(values)
      VectorParameterVersion.transaction(requires_new: true) do
        connection = VectorParameterVersion.connection
        connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(LOCK)}))")
        number = VectorParameterVersion.maximum(:version).to_i + 1
        row = VectorParameterVersion.create!(version: number, values: normalized, created_by_user: by)
        DomainEvents.publish(EVENT, version: row.version, user_id: by.id)
        Result.ok(version: row)
      end
    end
  end
end
