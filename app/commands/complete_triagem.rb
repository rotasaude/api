# Avança uma triagem com uma nova resposta. Ver ADR-0006 e ADR-0017.
# Reasons possíveis: :no_consent, :already_completed, :invalid_answer.
class CompleteTriagem
  def self.call(triagem:, answer:)
    new(triagem: triagem, answer: answer).call
  end

  def initialize(triagem:, answer:)
    @triagem = triagem
    @answer = answer
  end

  def call
    return Result.fail(:no_consent)         unless @triagem.conversation.consented?
    return Result.fail(:already_completed)  if @triagem.status_completed?

    outcome = nil
    ApplicationRecord.transaction do
      @triagem.with_lock do
        outcome = @triagem.record_answer!(@answer)
        return Result.fail(:invalid_answer) if outcome.terminal? && outcome.tier.nil?

        @triagem.append_answer!(@answer)

        if outcome.terminal?
          @triagem.complete!(outcome)
          DomainEvents.publish("triagem.completed", triagem_id: @triagem.id, **outcome.to_h)
          DomainEvents.publish("triagem.urgent",    triagem_id: @triagem.id, **outcome.to_h) if outcome.tier == "alta"
        end
      end
    end

    Result.ok(triagem: @triagem, outcome: outcome)
  end
end
