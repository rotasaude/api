# Regras por aparelho e analito (contrato §3; Desvio 3; C16; C-E2; C-E11): as
# seis chaves, booleanas; desligar uma regra que estava ligada exige
# justificativa; justificativa acima de 1000 → invalid_reason. Acrescenta uma
# versão (aparelho travado: a leitura da anterior e a gravação não se cruzam
# com um valor sendo avaliado); vale para os valores seguintes.
module Lab
  module Qc
    module SaveRules
      KEY = /\A[a-z0-9_]{1,40}\z/
      MAX_JUSTIFICATION = 1000

      module_function

      def call(instrument:, analyte_key:, rules:, justification:, by:, now: Time.current)
        rules = rules.to_unsafe_h if rules.respond_to?(:to_unsafe_h)
        valid = analyte_key.is_a?(String) && analyte_key.match?(KEY) && rules.is_a?(Hash) &&
                rules.keys.map(&:to_s).sort == LabQcRule::RULES.sort && rules.values.all? { |v| [ true, false ].include?(v) }
        return Result.fail(:invalid_rules) unless valid
        return Result.fail(:invalid_reason) unless justification.nil? || justification.is_a?(String)

        rules = rules.to_h.transform_keys(&:to_s)
        text = justification.to_s.strip
        return Result.fail(:invalid_reason) if text.length > MAX_JUSTIFICATION

        ApplicationRecord.transaction(requires_new: true) do
          instrument.lock!
          before = LabQcRule.enabled_for(instrument.id, analyte_key)
          turning_off = rules.any? { |rule, on| on == false && before.include?(rule) }
          next Result.fail(:justification_required) if turning_off && text.empty?

          rule = LabQcRule.create!(lab_instrument: instrument, analyte_key: analyte_key, rules: rules, justification: text.presence,
                                   changed_by_user: by, created_at: now)
          DomainEvents.publish("lab_qc_rule.changed", lab_qc_rule_id: rule.id, lab_instrument_id: instrument.id)
          Result.ok(rule: rule)
        end
      end
    end
  end
end
