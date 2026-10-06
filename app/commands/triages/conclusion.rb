# Início comum das regras da conclusão (Triages::Suggest, ADR 0027;
# Triages::Schedule, ADR 0029): nada se o resultado é urgente
# (Protocols::Urgency), se a conversa não tem cidadão (WhatsApp) ou se a versão
# EXATA da triagem não tem regras na chave pedida. Senão devolve o cidadão, as
# regras e o contexto das condições (perfil + respostas + resultado).
module Triages
  module Conclusion
    Rules = Data.define(:citizen, :rules, :context)

    module_function

    def rules_for(triage:, outcome:, key:, on:)
      return nil if Protocols::Urgency.urgent?(outcome)

      citizen = triage.conversation.citizen
      rules = triage.protocol_definition.definition[key]
      return nil unless citizen && rules.is_a?(Array) && rules.any?

      context = Protocols::ConditionContext.build(
        answers: triage.answers, profile: citizen.profile_context(on: on),
        outcome: { tier: outcome.tier, score: outcome.score, priority: outcome.priority }
      )
      Rules.new(citizen: citizen, rules: rules, context: context)
    end
  end
end
