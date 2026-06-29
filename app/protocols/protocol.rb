# Agregado raiz do motor. Módulo puro — ver ADR-0013.
# Recebe answers (Hash step_id -> answer) e retorna o próximo passo ou um Outcome.
module Protocols
  class Protocol
    attr_reader :name, :version, :steps, :start_step_id, :scoring

    def initialize(name:, version:, steps:, start_step_id:, scoring: nil)
      @name = name
      @version = version
      @steps = steps.each_with_object({}) { |s, acc| acc[s.id] = s }
      @start_step_id = start_step_id.to_sym
      @scoring = scoring
      freeze
    end

    # Próximo passo dado o estado atual. Retorna Step ou :pending se faltar
    # resposta, ou nil se o fluxo já terminou (caller chama #evaluate).
    def step(answers)
      cursor = start_step_id
      while (current = steps[cursor])
        answer = answers[current.id.to_s] || answers[current.id]
        return current if answer.nil?
        next_id = current.next_step_id(answer)
        return nil if next_id.nil?     # acabou o fluxo
        cursor = next_id.to_sym
      end
      nil
    end

    # Caminha o fluxo até o fim e devolve um Outcome (ADR-0015).
    # Scoring (ADR-0017) decide tier/priority a partir do trail.
    def evaluate(answers)
      trail = []
      cursor = start_step_id
      while (current = steps[cursor])
        answer = answers[current.id.to_s] || answers[current.id]
        return Outcome.pending(trail: trail, awaiting: current.id) if answer.nil?
        trail << { step: current.id, answer: answer, weight: current.weight_for(answer) }
        next_id = current.next_step_id(answer)
        break if next_id.nil?
        cursor = next_id.to_sym
      end

      scoring ? scoring.call(trail) : Outcome.terminal(trail: trail)
    end

    def to_h
      {
        name: name,
        version: version,
        start_step_id: start_step_id.to_s,
        steps: steps.values.map(&:to_h),
        scoring: scoring&.to_h
      }.compact
    end
  end
end
