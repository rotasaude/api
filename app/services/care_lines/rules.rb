# Validação única das regras de uma linha (ADR 0040; plano, Desvio 1): o
# catálogo-base (maintenance) e as linhas próprias da cidade usam esta.
# Recusa com o caminho do campo (nunca corta nem conserta em silêncio).
module CareLines
  module Rules
    PRACTICE_KEYS = %w[key label citizen_label source anchor window_start_days window_days min_count schedule
                       cbo_filter code_filter applies_to all_of points].freeze
    ELIGIBILITY_KEYS = %w[problems exclude_problems age_min_days age_max_days age_min_years age_max_years sex
                          gender_identities_included gender_identities_excluded declared requires_anchor].freeze
    CODE_FORMATS = { "ciap2" => /\A[A-Z]\d{2}\z/, "cid10" => /\A[A-Z]\d{2}[0-9X]?\z/ }.freeze
    MAX_PRACTICES = 20
    MAX_CODES = 300
    SEXES = %w[female male].freeze

    class Invalid < StandardError
      attr_reader :field

      def initialize(field)
        @field = field
        super("regra inválida")
      end
    end

    module_function

    def practices(list, template: false)
      raise Invalid, "practices" unless list.is_a?(Array) && list.size.between?(1, MAX_PRACTICES)

      normalized = list.each_with_index.map { |raw, index| practice(raw, "practices[#{index}]") }
      keys = normalized.map { |p| p["key"] }
      duplicate = keys.each_index.find { |i| keys.index(keys[i]) != i }
      raise Invalid, "practices[#{duplicate}].key" if duplicate
      raise Invalid, "practices.points" if template && normalized.sum { |p| p["points"].to_i } != 100

      Result.ok(practices: normalized)
    rescue Invalid => e
      Result.fail(:invalid_practices, details: { field: e.field })
    end

    def eligibility(raw)
      raise Invalid, "eligibility" unless raw.is_a?(Hash)

      raw = raw.stringify_keys
      unknown = (raw.keys - ELIGIBILITY_KEYS).first
      raise Invalid, "eligibility.#{unknown}" if unknown

      rules = {
        "problems" => codes(raw["problems"], "eligibility.problems"),
        "exclude_problems" => codes(raw["exclude_problems"], "eligibility.exclude_problems"),
        "sex" => enum(raw["sex"], SEXES, "eligibility.sex"),
        "gender_identities_included" => list(raw["gender_identities_included"], Citizen::GENDER_IDENTITIES, "eligibility.gender_identities_included"),
        "gender_identities_excluded" => list(raw["gender_identities_excluded"], Citizen::GENDER_IDENTITIES, "eligibility.gender_identities_excluded"),
        "declared" => list(raw["declared"], Catalog::CONDITIONS - %w[none], "eligibility.declared"),
        "requires_anchor" => enum(raw["requires_anchor"], %w[lmp], "eligibility.requires_anchor")
      }
      %w[age_min_days age_max_days].each { |k| rules[k] = int(raw[k], 0..47_450, "eligibility.#{k}") }
      %w[age_min_years age_max_years].each { |k| rules[k] = int(raw[k], 0..130, "eligibility.#{k}") }
      order!(rules, "age_min_days", "age_max_days", "eligibility")
      order!(rules, "age_min_years", "age_max_years", "eligibility")
      criteria = rules.values_at("problems", "age_min_days", "age_max_days", "age_min_years", "age_max_years", "sex", "declared")
      raise Invalid, "eligibility" if criteria.all?(&:nil?)

      Result.ok(eligibility: rules.compact)
    rescue Invalid => e
      Result.fail(:invalid_eligibility, details: { field: e.field })
    end

    def practice(raw, path)
      raise Invalid, path unless raw.is_a?(Hash)

      raw = raw.stringify_keys
      unknown = (raw.keys - PRACTICE_KEYS).first
      raise Invalid, "#{path}.#{unknown}" if unknown

      source = raw["source"].to_s
      raise Invalid, "#{path}.source" unless source.match?(Catalog::SOURCE_FORMAT)

      anchor = enum(raw["anchor"], Catalog::ANCHORS, "#{path}.anchor") || raise(Invalid, "#{path}.anchor")
      window = int(raw["window_days"], 1..7300, "#{path}.window_days") || raise(Invalid, "#{path}.window_days")
      start = int(raw["window_start_days"], 0..7299, "#{path}.window_start_days") || 0
      raise Invalid, "#{path}.window_start_days" if start.positive? && (anchor == "rolling" || start >= window)

      schedule = enum(raw["schedule"], Catalog::SCHEDULES, "#{path}.schedule") || "end_of_window"
      raise Invalid, "#{path}.schedule" if schedule == "proportional" && anchor == "rolling"

      all_of = groups(raw["all_of"], "#{path}.all_of")
      min_count = int(raw["min_count"], 1..50, "#{path}.min_count") || 1
      raise Invalid, "#{path}.min_count" if all_of && all_of.size > 1 && min_count != 1
      # O marco proporcional é de um grupo só; com vários grupos a avaliação ignoraria os demais.
      raise Invalid, "#{path}.schedule" if schedule == "proportional" && all_of && all_of.size > 1

      consultation = source == "consultation"
      cbo = raw["cbo_filter"]
      unless cbo.nil?
        raise Invalid, "#{path}.cbo_filter" unless consultation && cbo.is_a?(Array) && cbo.size.between?(1, 30) &&
                                                   cbo.all? { |c| c.is_a?(String) && c.match?(/\A\d{4,6}\z/) }
      end
      code_filter = raw["code_filter"].nil? ? nil : codes(raw["code_filter"], "#{path}.code_filter")
      raise Invalid, "#{path}.code_filter" if code_filter && !consultation

      {
        "key" => text(raw["key"], /\A[a-z0-9_]{1,40}\z/, "#{path}.key"),
        "label" => text(raw["label"], /\A.{1,120}\z/m, "#{path}.label"),
        "citizen_label" => raw["citizen_label"].nil? ? nil : text(raw["citizen_label"], /\A.{1,80}\z/m, "#{path}.citizen_label"),
        "source" => source, "anchor" => anchor, "window_start_days" => start, "window_days" => window,
        "min_count" => min_count, "schedule" => schedule, "cbo_filter" => cbo, "code_filter" => code_filter,
        "applies_to" => applies_to(raw["applies_to"], "#{path}.applies_to"), "all_of" => all_of,
        "points" => int(raw["points"], 0..100, "#{path}.points")
      }
    end

    def groups(raw, path)
      return nil if raw.nil?
      raise Invalid, path unless raw.is_a?(Array) && raw.size.between?(1, 6)

      raw.map do |group|
        raise Invalid, path unless group.is_a?(Array) && group.size.between?(1, 12)

        group.map do |alt|
          raise Invalid, path unless alt.is_a?(Hash)

          alt = alt.stringify_keys
          source = alt["source"].to_s
          raise Invalid, path unless (alt.keys - %w[source window_days]).empty? && source.match?(Catalog::SOURCE_FORMAT) &&
                                     !Catalog.untracked?(source)

          { "source" => source, "window_days" => int(alt["window_days"], 1..7300, path) }.compact
        end
      end
    end

    def applies_to(raw, path)
      return nil if raw.nil?
      raise Invalid, path unless raw.is_a?(Hash) && (raw.keys.map(&:to_s) - %w[age_min_years age_max_years sex]).empty?

      raw = raw.stringify_keys
      rules = { "age_min_years" => int(raw["age_min_years"], 0..130, path), "age_max_years" => int(raw["age_max_years"], 0..130, path),
                "sex" => enum(raw["sex"], SEXES, path) }
      order!(rules, "age_min_years", "age_max_years", path)
      rules.compact.presence || raise(Invalid, path)
    end

    # Lista vazia vale como ausente (§11 T7: a ida e volta do maintenance manda
    # { ciap2: [], cid10: [] }; a linha própria do dashboard, declared: []).
    # Código mal formado continua recusado; nada é cortado.
    def codes(raw, path)
      return nil if raw.nil?
      raise Invalid, path unless raw.is_a?(Hash) && (raw.keys.map(&:to_s) - CODE_FORMATS.keys).empty?

      normalized = raw.stringify_keys.each_with_object({}) do |(terminology, list), out|
        valid = list.is_a?(Array) && list.size <= MAX_CODES &&
                list.all? { |code| code.is_a?(String) && code.match?(CODE_FORMATS.fetch(terminology)) }
        raise Invalid, path unless valid

        out[terminology] = list.uniq if list.any?
      end
      normalized.presence
    end

    def list(raw, allowed, path)
      return nil if raw.nil? || raw == []
      raise Invalid, path unless raw.is_a?(Array) && raw.all? { |v| allowed.include?(v) }

      raw.uniq
    end

    def enum(raw, allowed, path)
      return nil if raw.nil?
      raise Invalid, path unless allowed.include?(raw)

      raw
    end

    def int(raw, range, path)
      return nil if raw.nil?
      raise Invalid, path unless raw.is_a?(Integer) && range.cover?(raw)

      raw
    end

    def text(raw, format, path)
      raise Invalid, path unless raw.is_a?(String) && raw.strip == raw && raw.match?(format)

      raw
    end

    def order!(rules, min_key, max_key, path)
      min, max = rules.values_at(min_key, max_key)
      raise Invalid, (path.include?(".") ? path : "#{path}.#{max_key}") if min && max && max < min
    end
    private_class_method :practice, :groups, :applies_to, :codes, :list, :enum, :int, :text, :order!
  end
end
