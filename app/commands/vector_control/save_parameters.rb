# Edição dos parâmetros técnicos pela coordenação (módulo 35a, ADR 0054;
# contrato §11, §12; A-4, A-5, Q17). Só a coordenação, com step-up (quem chama
# confere). `values` traz as 20 chaves do defaults.yml, nenhuma a mais nem a
# menos (VectorControl::Parameters.validate); recusa → invalid_parameter com o
# path `values.<chave>` (`values` quando não é objeto), só o primeiro erro.
#
# Cada edição cria a versão seguinte (vector_parameter_versions é só
# acréscimo, por trigger): sem linha, a vigente é a 0 (o defaults.yml) e a
# primeira edição grava a 1. Um advisory lock da transação serializa dois PUTs;
# a validação inteira (inclusive block_diseases contra a versão vigente) e a
# leitura da maior versão rodam depois dele. O índice único em `version` é o
# cinto.
# `vector_parameters.changed` com `version` e `user_id` (§17).
module VectorControl
  module SaveParameters
    LOCK = "vector_parameter_versions".freeze
    EVENT = "vector_parameters.changed".freeze

    module_function

    # -> Result.ok(version: VectorParameterVersion) | fail(:invalid_parameter, details: { path: })
    def call(values:, by:)
      VectorParameterVersion.transaction(requires_new: true) do
        connection = VectorParameterVersion.connection
        connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(LOCK)}))")
        # Depois da trava: block_diseases confere contra a versão vigente, que
        # outro PUT não muda mais até o fim desta transação. Recusa sai antes
        # de qualquer escrita.
        refusal = Parameters.validate(values)
        next Result.fail(:invalid_parameter, details: { path: [ "values", refusal[:path] ].compact.join(".") }) if refusal

        number = VectorParameterVersion.maximum(:version).to_i + 1
        row = VectorParameterVersion.create!(version: number, values: Parameters.normalize(values), created_by_user: by)
        DomainEvents.publish(EVENT, version: row.version, user_id: by.id)
        Result.ok(version: row)
      end
    end
  end
end
