# O passo atual da triagem, como a tela da web precisa: todas as opções (sem os
# limites do WhatsApp), progresso e se dá para voltar.
module Citizens
  module StepPayload
    module_function

    def for(triage)
      step = triage.protocol.steps[triage.current_step.to_sym]
      answered = triage.answers.size
      {
        triage_id: triage.id,
        step_id: step.id.to_s,
        prompt: step.prompt,
        answer_type: step.answer_type.to_s,
        options: options_for(step),
        index: answered + 1,
        total: [triage.protocol.steps.size, answered + 1].max,
        can_undo: answered.positive?
      }
    end

    def options_for(step)
      case step.answer_type
      when :boolean
        [{ id: "true", title: I18n.t("citizen.yes") }, { id: "false", title: I18n.t("citizen.no") }]
      when :enum
        Array(step.options).map { |o| { id: o.to_s, title: o.to_s } }
      else
        []
      end
    end
  end
end
