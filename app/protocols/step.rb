# Passo individual de um Protocol. Módulo puro — ver ADR-0013.
module Protocols
  class Step
    attr_reader :id, :prompt, :answer_type, :options, :branches, :weights

    def initialize(id:, prompt:, answer_type:, options: nil, branches: {}, weights: {})
      @id = id.to_sym
      @prompt = prompt
      @answer_type = answer_type.to_sym       # :boolean, :enum, :integer, :text
      @options = options                       # somente para :enum
      @branches = branches.transform_keys(&:to_s)  # answer_value -> next_step_id
      @weights = weights.transform_keys(&:to_s)    # answer_value -> peso numérico
      freeze
    end

    def next_step_id(answer)
      branches.fetch(answer.to_s, nil)
    end

    def weight_for(answer)
      weights.fetch(answer.to_s, 0)
    end

    def to_h
      {
        id: id.to_s,
        prompt: prompt,
        answer_type: answer_type.to_s,
        options: options,
        branches: branches,
        weights: weights
      }.compact
    end
  end
end
