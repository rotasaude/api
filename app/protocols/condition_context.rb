# Contexto plano da linguagem de condição (ADR 0009, ADR 0027; spec 2026-10-05
# §4.1). Módulo puro: quem chama calcula a idade (Citizen#age) e passa valores.
# Variáveis reservadas viram texto — eq/in comparam texto e gt/gte/lt/lte
# convertem com Float, como sempre fizeram com as respostas. nil não entra
# (variável ausente → condição falsa). Resposta cujo id começa por prefixo
# reservado é descartada: o gate recusa esse id, e a variável sempre vence.
module Protocols
  module ConditionContext
    RESERVED_PREFIXES = %w[profile. outcome. citizen. vitals. complaint.].freeze
    # ADR 0030: sinais vitais da escuta (spec §3.1) e o IMC calculado.
    VITALS = %w[systolic diastolic heart_rate respiratory_rate temperature_c spo2 capillary_glucose glucose_moment
                weight_kg height_cm bmi pain_score].freeze

    module_function

    def reserved?(name) = name.to_s.start_with?(*RESERVED_PREFIXES)

    def build(answers: {}, profile: {}, outcome: {}, citizen: {}, vitals: {}, complaint: {})
      context = {}
      (answers.is_a?(Hash) ? answers : {}).each { |key, value| context[key.to_s] = value unless reserved?(key) }
      profile = symbolize(profile)
      outcome = symbolize(outcome)
      citizen = symbolize(citizen)
      vitals = symbolize(vitals)
      complaint = symbolize(complaint)
      put(context, "profile.age", profile[:age])
      put(context, "profile.sex", profile[:sex])
      put(context, "outcome.tier", outcome[:tier])
      put(context, "outcome.score", outcome[:score])
      put(context, "outcome.priority", outcome[:priority])
      put(context, "citizen.neighborhood_id", citizen[:neighborhood_id])
      VITALS.each { |field| put(context, "vitals.#{field}", vitals[field.to_sym]) }
      put(context, "complaint.ciap2", complaint[:ciap2])
      context
    end

    def symbolize(hash) = hash.is_a?(Hash) ? hash.transform_keys(&:to_sym) : {}

    def put(context, key, value)
      return if value.nil?

      context[key] = value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
    end
  end
end
