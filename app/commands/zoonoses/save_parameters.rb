# Edição dos parâmetros técnicos pela coordenação (módulo 35b, ADR 0054;
# contrato §9, Q18, Q32, Q34; molde do VectorControl::SaveParameters). Só a
# coordenação, com step-up (quem chama confere). `values` traz as 8 chaves do
# defaults.yml, nenhuma a mais nem a menos (Zoonoses::Parameters.validate);
# recusa → invalid_parameter com o path `values.<chave>` (`values` quando não
# é objeto), só o primeiro erro.
#
# Cada edição cria a versão seguinte (zoonoses_parameter_versions é só
# acréscimo, por trigger): sem linha, a vigente é a 0 (o defaults.yml) e a
# primeira edição grava a 1. Um advisory lock da transação serializa dois PUTs;
# o índice único em `version` é o cinto.
#
# Concorrência otimista (Q34): `expected_version` é a versão que a tela leu
# (0 = o defaults.yml). Ausente → expected_version_required; fora de inteiro
# >= 0 → invalid_request, ambos com o path `expected_version`. Divergiu da
# vigente (conferido depois da trava) → parameters_changed, nada gravado e
# nenhum evento. A versão nova vale só para o que nasce depois dela: a
# observação aberta guarda o ends_on da abertura. `zoonoses_parameters.changed`
# só com ids.
module Zoonoses
  module SaveParameters
    LOCK = "zoonoses_parameter_versions".freeze
    EVENT = "zoonoses_parameters.changed".freeze

    module_function

    # -> Result.ok(version: ZoonosesParameterVersion) | fail(:invalid_parameter, details: { path: })
    #    | fail(:expected_version_required | :invalid_request, details: { path: "expected_version" })
    #    | fail(:parameters_changed)
    def call(values:, by:, expected_version:)
      return Result.fail(:expected_version_required, details: { path: "expected_version" }) if expected_version.nil?
      unless expected_version.is_a?(Integer) && expected_version >= 0
        return Result.fail(:invalid_request, details: { path: "expected_version" })
      end

      ZoonosesParameterVersion.transaction(requires_new: true) do
        connection = ZoonosesParameterVersion.connection
        connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(LOCK)}))")
        current = ZoonosesParameterVersion.maximum(:version).to_i
        next Result.fail(:parameters_changed) unless expected_version == current

        refusal = Parameters.validate(values)
        next Result.fail(:invalid_parameter, details: { path: [ "values", refusal[:path] ].compact.join(".") }) if refusal

        row = ZoonosesParameterVersion.create!(version: current + 1, values: Parameters.normalize(values), created_by_user: by)
        DomainEvents.publish(
          EVENT,
          zoonoses_parameter_version_id: row.id,
          user_id: by.id
        )
        Result.ok(version: row)
      end
    end
  end
end
