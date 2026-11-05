# Situação de rua do mês (ADR 0049; contrato §6, P6): `PATCH
# /psychosocial/monthly_records/:id { homeless: Boolean }`. Só a chave
# `homeless`, sempre booleana (senão 422 invalid_request com o path). Trava a
# linha do CAPS (FOR SHARE: o fechamento do mês trava FOR NO KEY UPDATE) e o registro;
# fora de `open` → 409 record_not_open.
module Psychosocial
  module UpdateMonthlyRecord
    KEYS = %w[homeless].freeze
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(record:) | fail(:record_not_open) | fail(:invalid_request, details: { path:, problems: })
    def call(record:, attrs:)
      attrs = attrs.to_h.stringify_keys
      unknown = (attrs.keys - KEYS).first
      return refuse(unknown[0, KEY_PATH_MAX]) if unknown
      return refuse("homeless") unless [ true, false ].include?(attrs["homeless"])

      ApplicationRecord.transaction(requires_new: true) do
        HealthUnit.lock("FOR SHARE").find(record.health_unit_id)
        record.lock!
        next Result.fail(:record_not_open) unless record.status == "open"

        record.update!(homeless: attrs["homeless"])
        Result.ok(record: record)
      end
    end

    def refuse(path)
      problem = { error: "invalid_request", path: path }
      Result.fail(:invalid_request, details: { path: path, problems: [ problem ] })
    end

    private_class_method :refuse
  end
end
