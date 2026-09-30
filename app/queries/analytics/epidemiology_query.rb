module Analytics
  # Epidemiologia (contratos §1.4): uma entrada por pergunta marcada
  # `analytic` (boolean/enum) nas versões que passaram pelo ciclo assinado
  # (desvio 11 do plano); prompt e opções da maior dessas versões.
  class EpidemiologyQuery < BaseQuery
    FILTERS = %i[neighborhood protocol version].freeze
    CYCLED = %w[published active retired].freeze
    BOOLEAN_OPTIONS = [ %w[true Sim], %w[false Não] ].freeze

    def call
      facts = sums("epi.answer", keys: %i[protocol_name question_id dim], filters: FILTERS)
      by_option = facts.each_with_object(Hash.new { |hash, key| hash[key] = Hash.new(0) }) do |((period, name, question, dim), value), acc|
        acc[[ name, question, dim ]][period] += value
      end
      { questions: catalog.map { |question| question_json(question, by_option) } }
    end

    private

    def catalog
      scope = ProtocolDefinition.where(status: CYCLED)
      scope = scope.where(name: params.protocol_name) if params.protocol_name
      latest = {}
      marked_in_version = Set.new
      scope.order(:name, :version).each do |definition|
        Array(definition.definition["steps"]).each_with_index do |step, position|
          next unless analytic?(step)

          key = [ definition.name, step["id"] ]
          latest[key] = { protocol_name: definition.name, question_id: step["id"], prompt: step["prompt"],
                          answer_type: step["answer_type"], options: step["options"], position: position }
          marked_in_version << key if params.protocol_version.nil? || definition.version == params.protocol_version
        end
      end
      latest.select { |key, _| marked_in_version.include?(key) }.values
            .sort_by { |question| [ question[:protocol_name], question[:position] ] }
    end

    def analytic?(step)
      step.is_a?(Hash) && step["analytic"] == true &&
        (step["answer_type"] == "boolean" || (step["answer_type"] == "enum" && step["options"].is_a?(Array)))
    end

    def question_json(question, by_option)
      options = if question[:answer_type] == "boolean"
                  BOOLEAN_OPTIONS
                else
                  question[:options].map { |option| [ option.to_s, option.to_s ] }
                end
      { protocol_name: question[:protocol_name], question_id: question[:question_id], prompt: question[:prompt],
        answer_type: question[:answer_type],
        options: options.map do |value, label|
          key = [ question[:protocol_name], question[:question_id], value ]
          { value: value, label: label, **row(by_option.fetch(key, {})) }
        end }
    end
  end
end
