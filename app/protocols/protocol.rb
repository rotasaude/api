# Agregado raiz do motor. Módulo puro — ver ADR-0009.
# Recebe answers (Hash step_id -> answer) e retorna o próximo passo ou um Outcome.
module Protocols
  class Protocol
    attr_reader :name, :version, :steps, :start_step_id, :scoring, :priority_rules

    def initialize(name:, version:, steps:, start_step_id:, scoring: nil, priority_rules: nil)
      @name = name
      @version = version
      @steps = steps.each_with_object({}) { |s, acc| acc[s.id] = s }
      @start_step_id = start_step_id.to_sym
      @scoring = scoring
      @priority_rules = priority_rules
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

    # Caminha o fluxo até o fim e devolve um Outcome (ADR-0009).
    # Scoring (ADR-0009) decide tier/priority a partir do trail.
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

      outcome = scoring ? scoring.call(trail) : Outcome.terminal(trail: trail)
      apply_priority_when(outcome, trail)
    end

    def to_h
      {
        name: name,
        version: version,
        start_step_id: start_step_id.to_s,
        steps: steps.values.map(&:to_h),
        scoring: scoring&.to_h,
        priority_when: priority_rules
      }.compact
    end

    private

    # Escala-só (F-03.6): priority_when só aumenta a urgência (min). Só terminal.
    def apply_priority_when(outcome, trail)
      return outcome unless outcome.terminal?
      answers = trail.to_h { |entry| [entry[:step].to_s, entry[:answer].to_s] }
      escalated = PriorityRules.override_for(priority_rules, answers)
      return outcome unless escalated
      final = [outcome.priority, escalated].compact.min
      return outcome if final == outcome.priority
      Outcome.terminal(trail: outcome.trail, tier: outcome.tier, priority: final, score: outcome.score)
    end
  end
end
