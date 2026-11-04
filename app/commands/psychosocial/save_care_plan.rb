# Projeto Terapêutico Singular (ADR 0049; contrato §4, P12, P13, P25): cada
# gravação é a versão N+1 da matrícula; as versões são imutáveis (trigger) e a
# revisão grava a seguinte. Campos:
#   needs (1..4000); goals (1..20 itens { text 1..500, responsible_user_id
#   lotado no CAPS, due_on? }); intensity (INTENSITIES); review_on (depois de
#   hoje e até hoje + 365).
# Texto acima do limite → too_long; vazio, fora da forma ou chave desconhecida
# → invalid_request; sempre com o path (`goals[0].text`) e todos de uma vez.
# Matrícula encerrada → 409 already_closed. A versão é a maior + 1 sob a trava
# da linha da matrícula; publica `psychosocial.care_plan_saved` só com o id.
module Psychosocial
  module SaveCarePlan
    KEYS = %w[needs goals intensity review_on].freeze
    GOAL_KEYS = %w[text responsible_user_id due_on].freeze
    KEY_PATH_MAX = 64
    REVIEW_MAX_DAYS = 365

    module_function

    # -> Result.ok(care_plan:) | fail(:already_closed) |
    #    fail(:invalid_request | :too_long, details: { path:, problems: })
    def call(enrollment:, attrs:, by:, today: Time.zone.today)
      return Result.fail(:already_closed) unless enrollment.open?

      attrs = attrs.to_h.stringify_keys
      values, problems = check(attrs, enrollment: enrollment, today: today)
      return failure(problems) if problems.any?

      ApplicationRecord.transaction(requires_new: true) do
        enrollment.lock!
        next Result.fail(:already_closed) unless enrollment.open?

        version = PsychosocialCarePlan.where(psychosocial_enrollment_id: enrollment.id).maximum(:version).to_i + 1
        plan = PsychosocialCarePlan.create!(psychosocial_enrollment: enrollment, version: version, created_by_user: by, **values)
        DomainEvents.publish("psychosocial.care_plan_saved", care_plan_id: plan.id)
        Result.ok(care_plan: plan)
      end
    end

    # -> [values, problems]
    def check(attrs, enrollment:, today:)
      problems = (attrs.keys - KEYS).map { |key| problem(key[0, KEY_PATH_MAX]) }
      values = {}

      needs = Catalog.text_problem(attrs["needs"], Catalog::NEEDS, "needs")
      needs ? problems << needs : values[:needs] = attrs["needs"].strip

      goals, goal_problems = goals(attrs["goals"], enrollment)
      goal_problems.any? ? problems.concat(goal_problems) : values[:goals] = goals

      Catalog::INTENSITIES.include?(attrs["intensity"]) ? values[:intensity] = attrs["intensity"] : problems << problem("intensity")

      review_on = Input.date(attrs["review_on"])
      if review_on && review_on > today && review_on <= today + REVIEW_MAX_DAYS
        values[:review_on] = review_on
      else
        problems << problem("review_on")
      end
      [ values, problems ]
    end

    # -> [[{ "text", "responsible_user_id", "due_on" }], problems]
    def goals(raw, enrollment)
      return [ nil, [ problem("goals") ] ] unless raw.is_a?(Array) && (1..Catalog::MAX_GOALS).cover?(raw.size)

      team = {}
      problems = []
      list = raw.each_with_index.map do |item, index|
        item, goal_problems = goal(item, index, enrollment, team)
        problems.concat(goal_problems)
        item
      end
      [ list, problems ]
    end

    def goal(item, index, enrollment, team)
      path = "goals[#{index}]"
      return [ nil, [ problem(path) ] ] unless item.is_a?(Hash)

      item = item.stringify_keys
      problems = (item.keys - GOAL_KEYS).map { |key| problem("#{path}.#{key[0, KEY_PATH_MAX]}") }
      text = Catalog.text_problem(item["text"], Catalog::GOAL_TEXT, "#{path}.text")
      problems << text if text

      responsible = item["responsible_user_id"]
      problems << problem("#{path}.responsible_user_id") unless on_team?(responsible, enrollment, team)

      due_on = item["due_on"]
      parsed = Input.date(due_on)
      problems << problem("#{path}.due_on") if !due_on.nil? && parsed.nil?

      [ { "text" => item["text"].to_s.strip, "responsible_user_id" => responsible, "due_on" => parsed&.iso8601 }, problems ]
    end

    # Responsável lotado no CAPS da matrícula (mesma regra do técnico de referência).
    def on_team?(user_id, enrollment, team)
      return false unless Input.uuid?(user_id)

      team.fetch(user_id) do
        user = User.find_by(id: user_id)
        team[user_id] = user.present? && Access.link(user, enrollment.health_unit_id).present?
      end
    end

    def problem(path, error = "invalid_request") = { error: error, path: path }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :check, :goals, :goal, :on_team?, :problem, :failure
  end
end
