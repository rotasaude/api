# Value Object de saída do motor. Imutável. Ver ADR-0015.
module Protocols
  class Outcome
    attr_reader :status, :tier, :priority, :trail, :awaiting, :score

    def self.pending(trail:, awaiting:)
      new(status: :pending, trail: trail, awaiting: awaiting)
    end

    def self.terminal(trail:, tier: nil, priority: nil, score: nil)
      new(status: :terminal, trail: trail, tier: tier, priority: priority, score: score)
    end

    def initialize(status:, trail:, tier: nil, priority: nil, awaiting: nil, score: nil)
      @status = status
      @trail = trail.freeze
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
        trail: trail
      }.compact
    end
  end
end
