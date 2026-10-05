# Contexto plano da linguagem de condição (ADR 0009, ADR 0027; spec 2026-10-05
# §4.1). Módulo puro: quem chama calcula a idade (Citizen#age) e passa valores.
# Variáveis reservadas viram texto — eq/in comparam texto e gt/gte/lt/lte
# convertem com Float, como sempre fizeram com as respostas. nil não entra
# (variável ausente → condição falsa). Resposta cujo id começa por prefixo
# reservado é descartada: o gate recusa esse id, e a variável sempre vence.
module Protocols
  module ConditionContext
    RESERVED_PREFIXES = %w[profile. outcome. citizen.].freeze

    module_function

    def reserved?(name) = name.to_s.start_with?(*RESERVED_PREFIXES)

    def build(answers: {}, profile: {}, outcome: {}, citizen: {})
      context = {}
      (answers.is_a?(Hash) ? answers : {}).each { |key, value| context[key.to_s] = value unless reserved?(key) }
      profile = symbolize(profile)
      outcome = symbolize(outcome)
      citizen = symbolize(citizen)
      put(context, "profile.age", profile[:age])
      put(context, "profile.sex", profile[:sex])
      put(context, "outcome.tier", outcome[:tier])
      put(context, "outcome.score", outcome[:score])
      put(context, "outcome.priority", outcome[:priority])
      put(context, "citizen.neighborhood_id", citizen[:neighborhood_id])
      context
    end

    def symbolize(hash) = hash.is_a?(Hash) ? hash.transform_keys(&:to_sym) : {}

    def put(context, key, value)
      context[key] = value.to_s unless value.nil?
    end
  end
end
