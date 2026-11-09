# Gate da variante kind "urgency_classification" (módulo 32a, ADR 0050;
# contrato §3 e §14 Q1/Q3). Roda DEPOIS do schema (protocols-v1.7.0), que já
# cuida da forma: as 5 cores na ordem, os limites de tempo, 1..100 regras, o
# padrão do id e o tamanho do critério. Aqui fica o que o schema não diz:
# - `rule_id`: id de regra repetido;
# - `levels_out_of_order`: tempo máximo menor que o da cor mais grave anterior;
# - as variáveis do `when`: vitals.* (sem pain_score), pain_scale (a dor, fora
#   de vitals — Q3) e profile.age/profile.sex. A queixa nunca entra.
# Não há nome reservado (Q16): o nome de outro kind é do Protocols::NameKindConflict.
# Total para qualquer entrada.
#
# Nota: dentro de Protocols, `Urgency` é o Protocols::Urgency (alerta da
# triagem); o domínio da urgência é sempre `::Urgency`.
module Protocols
  module Validation
    module Urgency
      KIND = "urgency_classification".freeze
      PAIN = "pain_scale".freeze
      VARIABLES = (Condition::VARIABLES.keys.grep(/\Avitals\./) - %w[vitals.pain_score] + %w[profile.age profile.sex]).freeze
      # pain_scale entra no contexto como resposta (inteiro 0..10), então o
      # linter o enxerga como um passo inteiro: aceita gt/gte/lt/lte/eq/in.
      PAIN_STEP = { PAIN => { "id" => PAIN, "answer_type" => "integer" } }.freeze

      module_function

      def urgency?(definition) = definition.is_a?(Hash) && definition["kind"] == KIND

      def call(definition)
        return [] unless urgency?(definition)

        level_errors(definition["levels"]) + rule_errors(definition["classification_rules"])
      end

      def level_errors(levels)
        return [] unless levels.is_a?(Array)

        levels.each_with_index.each_cons(2).filter_map do |(previous, _), (level, index)|
          next unless previous.is_a?(Hash) && level.is_a?(Hash)
          next unless previous["max_wait_minutes"].is_a?(Integer) && level["max_wait_minutes"].is_a?(Integer)
          next unless level["max_wait_minutes"] < previous["max_wait_minutes"]

          "levels_out_of_order: levels[#{index}] (#{level["color"]}, #{level["max_wait_minutes"]} min) waits less than " \
            "levels[#{index - 1}] (#{previous["color"]}, #{previous["max_wait_minutes"]} min)"
        end
      end

      def rule_errors(rules)
        return [] unless rules.is_a?(Array)

        seen = Set.new
        rules.each_with_index.flat_map do |rule, index|
          next [] unless rule.is_a?(Hash)

          errors = []
          errors << "rule_id: duplicate id '#{rule["id"]}' at classification_rules[#{index}]" unless seen.add?(rule["id"])
          errors + Condition.errors(rule["when"], PAIN_STEP, variables: VARIABLES)
                            .map { |e| "classification_rules[#{index}].when: #{e}" }
        end
      end
    end
  end
end
