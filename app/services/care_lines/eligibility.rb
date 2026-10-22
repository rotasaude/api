# Elegibilidade (ADR 0040; spec §2 decisões 2, 8 e 9). PURA. Problema
# ativo por prefixo de código (CID sem ponto); faixa de idade (dias ou anos)
# e sexo (com identidade de gênero incluída/excluída — C7, caderno 4.1–4.2);
# declaração do cidadão só sugere, nunca entra no denominador.
module CareLines
  module Eligibility
    module_function

    def match(rules, person, on:)
      return nil if rules["exclude_problems"] && codes_match?(rules["exclude_problems"], person.problems)
      return nil unless demographics?(rules, person, on)
      return "problem" if rules["problems"] && codes_match?(rules["problems"], person.problems)
      return "age_sex" if rules["problems"].nil? && rules["declared"].nil? && demographic_rule?(rules)
      return "declared" if (Array(rules["declared"]) & person.declared).any?

      nil
    end

    def denominator?(rules, person, on:) = %w[problem age_sex].include?(match(rules, person, on: on))

    def closure?(rules, person)
      return false unless rules["problems"]

      !codes_match?(rules["problems"], person.problems) && codes_match?(rules["problems"], person.resolved_problems)
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
    private_class_method :demographic_rule?, :demographics?
  end
end
