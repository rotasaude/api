# Value Object de saída do motor. Imutável. Ver ADR-0009.
module Protocols
  class Outcome
    # explanation (F-03.7): por que o motor chegou ao tier/priority — entradas
    # { ev:, rule:, ref:, out: } com ev em scored/rule_matched/priority_rule/
    # tier_assigned. Só referências (passo, índice de regra, peso, tier);
    # NUNCA a resposta crua.
    attr_reader :status, :tier, :priority, :trail, :awaiting, :score, :explanation

    def self.pending(trail:, awaiting:)
      new(status: :pending, trail: trail, awaiting: awaiting)
    end

    def self.terminal(trail:, tier: nil, priority: nil, score: nil, explanation: [])
      new(status: :terminal, trail: trail, tier: tier, priority: priority, score: score, explanation: explanation)
    end

    def initialize(status:, trail:, tier: nil, priority: nil, awaiting: nil, score: nil, explanation: [])
      @status = status
      @trail = trail.freeze
      @explanation = explanation.map(&:freeze).freeze
      @tier = tier
      @priority = priority
      @awaiting = awaiting
      @score = score
      freeze
    end

    def pending?  = status == :pending
    def terminal? = status == :terminal

    def to_h
      {
        status: status.to_s,
        tier: tier,
        priority: priority,
        score: score,
        awaiting: awaiting&.to_s,
        trail: trail,
        explanation: (explanation unless explanation.empty?)
      }.compact
    end
  end
end
