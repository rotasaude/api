# Avança uma triage com uma nova resposta. Ver ADR-0006 e ADR-0017.
# Reasons possíveis: :no_consent, :already_completed, :invalid_answer.
class CompleteTriage
  def self.call(triage:, answer:)
    new(triage: triage, answer: answer).call
  end

  def initialize(triage:, answer:)
    @triage = triage
    @answer = answer
  end

  def call
    return Result.fail(:no_consent)         unless @triage.conversation.consented?
    return Result.fail(:already_completed)  if @triage.status_completed?

    outcome = nil
    ApplicationRecord.transaction do
      @triage.with_lock do
        outcome = @triage.record_answer!(@answer)
        return Result.fail(:invalid_answer) if outcome.terminal? && outcome.tier.nil?

        @triage.append_answer!(@answer)

        if outcome.terminal?
          @triage.complete!(outcome)
          DomainEvents.publish("triage.completed", triage_id: @triage.id, **outcome.to_h)
          DomainEvents.publish("triage.urgent",    triage_id: @triage.id, **outcome.to_h) if outcome.tier == "alta"
        end
      end
    end

    Result.ok(triage: @triage, outcome: outcome)
  end
end
