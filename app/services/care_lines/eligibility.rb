# Elegibilidade (ADR 0040; spec §2 decisões 2, 8 e 9). PURA. Problema
# ativo por prefixo de código (CID sem ponto); faixa de idade (dias ou anos)
# e sexo (com identidade de gênero incluída/excluída — C7, caderno 4.1–4.2);
# declaração do cidadão só sugere, nunca entra no denominador.
module CareLines
  module Eligibility
    module_function

    # Gestação atual: a partir da DUM (`lmp:`, inscrita) ou, sem DUM, nos 294
    # dias até `on`.
    PREGNANCY_WINDOW_DAYS = 294

    def match(rules, person, on:, lmp: nil)
      return nil if rules["exclude_problems"] && excluded?(rules["exclude_problems"], person, on, lmp)
      return nil unless demographics?(rules, person, on)
      return "problem" if rules["problems"] && codes_match?(rules["problems"], person.problems)
      return "age_sex" if rules["problems"].nil? && rules["declared"].nil? && demographic_rule?(rules)
      return "declared" if (Array(rules["declared"]) & person.declared).any?

      nil
    end

    def denominator?(rules, person, on:, lmp: nil) = %w[problem age_sex].include?(match(rules, person, on: on, lmp: lmp))

    def closure?(rules, person)
      return false unless rules["problems"]

      !codes_match?(rules["problems"], person.problems) && codes_match?(rules["problems"], person.resolved_problems)
    end

    # O problema excludente só vale se foi registrado na gestação atual. Sem
    # data em problem_since a data é desconhecida: não dá para afirmar que é
    # da gestação atual, então não exclui (ruling do controlador).
    def excluded?(rules, person, on, lmp)
      from = lmp || on - PREGNANCY_WINDOW_DAYS
      current = person.problems.select do |pair|
        since = person.problem_since[pair]
        since && since >= from && since <= on
      end
      codes_match?(rules, current)
    end

    def codes_match?(rules, pairs)
      pairs.any? { |terminology, code| Array(rules[terminology]).any? { |prefix| code.start_with?(prefix) } }
    end

    def demographic_rule?(rules)
      %w[age_min_days age_max_days age_min_years age_max_years sex].any? { |key| rules[key] }
    end

    def demographics?(rules, person, on)
      days = person.age_days(on)
      years = person.age_years(on)
      if rules["age_min_days"] || rules["age_max_days"]
        return false if days.nil? || (rules["age_min_days"] && days < rules["age_min_days"]) ||
                        (rules["age_max_days"] && days > rules["age_max_days"])
      end
      if rules["age_min_years"] || rules["age_max_years"]
        return false if years.nil? || (rules["age_min_years"] && years < rules["age_min_years"]) ||
                        (rules["age_max_years"] && years > rules["age_max_years"])
      end
      return false if Array(rules["gender_identities_excluded"]).include?(person.gender_identity)
      return true if rules["sex"].nil?

      person.sex == rules["sex"] || Array(rules["gender_identities_included"]).include?(person.gender_identity)
    end
    private_class_method :excluded?, :demographic_rule?, :demographics?
  end
end
