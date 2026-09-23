# O motor não recusa resposta fora do esperado: sem ramo, o fluxo acaba e
# pontua (Protocols::Protocol#evaluate). No WhatsApp isso é mitigado por botões;
# na web, a resposta é conferida contra o passo ANTES do CompleteTriage
# (spec 2026-09-22-web-citizen-channel §3.2).
module Citizens
  module AnswerValidator
    TEXT_MAX = 500

    module_function

    def valid?(step, answer)
      value = answer.to_s
      case step.answer_type
      when :boolean then %w[true false].include?(value)
      when :enum    then Array(step.options).map(&:to_s).include?(value)
      when :integer then value.match?(/\A\d{1,4}\z/)
      else value.strip.length.between?(1, TEXT_MAX)
      end
    end
  end
end
