# Uma resposta da web. Tudo sob o lock da conversa: duas abas ou um toque duplo
# não avançam a triagem duas vezes. A mesma idempotency_key devolve o estado
# atual sem gravar (spec §4.3).
# Ordem de lock cidadão → conversa (desvio 5 do plano), a mesma de
# StartConversation e Citizens::Erase: na conclusão, Triages::Suggest grava
# triage_suggestions, cuja FK pega FOR KEY SHARE no cidadão; travar só a
# conversa fecharia um ciclo com quem trava o cidadão antes (deadlock).
# O cidadão vai em FOR NO KEY UPDATE (como Placement.lock!): exclui as outras
# travas do cidadão, mas deixa passar o FOR KEY SHARE das FKs de quem grava
# linhas do cidadão. Com FOR UPDATE, a conclusão (Triages::Schedule grava o
# pedido, FK na unidade, ou trava o pedido vivo na fusão) cruzava com
# HealthUnits::Drain, que trava a unidade e os pedidos e grava o pedido novo
# com FK no cidadão: deadlock (spec/commands/triages/schedule_drain_concurrency_spec.rb).
# StartConversation e StartTriage usam o mesmo modo (sem promover a trava).
# Conversa sem cidadão (WhatsApp) trava só a conversa.
# Reasons: :invalid_answer, :not_in_progress (e as de CompleteTriage).
module Citizens
  class SubmitAnswer
    def self.call(conversation:, answer:, idempotency_key:)
      new(conversation, answer.to_s.strip, idempotency_key.presence).call
    end

    def initialize(conversation, answer, idempotency_key)
      @conversation = conversation
      @answer = answer
      @idempotency_key = idempotency_key
    end

    def call
      result = nil
      ApplicationRecord.transaction do
        @conversation.citizen&.lock!("FOR NO KEY UPDATE")
        @conversation.lock!
        result = locked_call
      end
      result
    end

    private

    def locked_call
      triage = @conversation.triages.order(created_at: :desc).first
      return Result.fail(:not_in_progress) unless triage
      return Result.ok(triage: triage, replayed: true) if replay?
      return Result.fail(:not_in_progress) unless triage.status_in_progress?

      step = triage.protocol.steps[triage.current_step.to_sym]
      return Result.fail(:invalid_answer) unless step && AnswerValidator.valid?(step, @answer)

      completed = CompleteTriage.call(triage: triage, answer: @answer)
      return completed if completed.failure?

      @conversation.update!(last_answer_key: @idempotency_key)
      @conversation.update!(state: :completed) if completed.payload[:outcome].terminal?
      Result.ok(triage: triage.reload, replayed: false)
    end

    def replay?
      @idempotency_key && @idempotency_key == @conversation.last_answer_key
    end
  end
end
