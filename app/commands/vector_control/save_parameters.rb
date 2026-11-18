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
#
# Concorrência otimista (Q34; o mesmo nome e a mesma forma do
# Protocols::RevertActivation): `expected_version` é a versão que a tela leu
# (0 = o defaults.yml, sem linha; A-4/Q10). Obrigatória, sem default na
# palavra-chave: `nil` (o cliente não mandou) → expected_version_required;
# fora de inteiro >= 0 → invalid_request, ambos com o path
# `expected_version`. Diferente do precedente, que lê string e trata o token
# ilegível como divergência: aqui o corpo é JSON e o 35a não converte tipo
# (Parameters.validate recusa "60"), então ilegível é pedido malformado. A
# conferência com a vigente roda DEPOIS da trava, a mesma da escrita: divergiu
# → parameters_changed (409), nada gravado e nenhum evento; a tela relê.
# `vector_parameters.changed` com `version` e `user_id` (§17).
module VectorControl
  module SaveParameters
    LOCK = "vector_parameter_versions".freeze
    EVENT = "vector_parameters.changed".freeze

    module_function

    # -> Result.ok(version: VectorParameterVersion) | fail(:invalid_parameter, details: { path: })
    #    | fail(:expected_version_required | :invalid_request, details: { path: "expected_version" })
    #    | fail(:parameters_changed)
    def call(values:, by:, expected_version:)
      if expected_version.nil?
        return Result.fail(:expected_version_required, details: { path: "expected_version" })
      end
      unless expected_version.is_a?(Integer) && expected_version >= 0
        return Result.fail(:invalid_request, details: { path: "expected_version" })
      end

      VectorParameterVersion.transaction(requires_new: true) do
        connection = VectorParameterVersion.connection
        connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(LOCK)}))")
        # Depois da trava: a versão vigente (0 sem linha) não muda mais até o
        # fim desta transação, e é contra ela que expected_version e
        # block_diseases conferem. Recusa sai antes de qualquer escrita.
        current = VectorParameterVersion.maximum(:version).to_i
        next Result.fail(:parameters_changed) unless expected_version == current

        refusal = Parameters.validate(values)
        next Result.fail(:invalid_parameter, details: { path: [ "values", refusal[:path] ].compact.join(".") }) if refusal

        number = current + 1
        row = VectorParameterVersion.create!(version: number, values: Parameters.normalize(values), created_by_user: by)
        DomainEvents.publish(EVENT, version: row.version, user_id: by.id)
        Result.ok(version: row)
      end
    end
  end
end
