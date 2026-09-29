# app/services/campaigns/audience_schema.rb
# Formato do público, versão 1 (ADR 0024; spec 2026-09-29 §4.1). Validação à
# mão, com caminho determinístico (ponteiro JSON relativo à raiz do público)
# para o editor do dashboard marcar o campo. Critério novo = entrada em
# CRITERIA + classe em Campaigns::Criteria. O JSON já comporta `clinical.any`
# depois; hoje só `all` (E).
module Campaigns
  module AudienceSchema
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    MAX_CRITERIA = 7
    MAX_NEIGHBORHOODS = 50
    MAX_TIERS = 20
    MAX_TEXT = 200

    GEO = { "city" => [], "unit" => %w[health_unit_id], "neighborhoods" => %w[neighborhood_ids] }.freeze

    CRITERIA = {
      "protocol_period" => { required: %w[protocol_name from to], optional: [] },
      "triage_tier" => { required: %w[tiers from to], optional: [] },
      "triage_incomplete" => { required: %w[from to], optional: [] },
      "attendance_outcome" => { required: %w[outcomes from to], optional: %w[health_unit_id] },
      "triaged_not_attended" => { required: %w[from to], optional: [] },
      "appointment_no_show" => { required: %w[from to], optional: [] },
      "appointment_request_open" => { required: [], optional: %w[kinds target_unit_id] }
    }.freeze

    module_function

    def errors(input)
      audience = normalize(input)
      return [ error("/", "not_an_object") ] unless audience.is_a?(Hash)

      found = shape_errors(audience, required: %w[version geo clinical], optional: [], path: "")
      found << error("/version", "must_be_1") if audience.key?("version") && audience["version"] != 1
      found.concat(geo_errors(audience["geo"])) if audience.key?("geo")
      found.concat(clinical_errors(audience["clinical"])) if audience.key?("clinical")
      found
    end

    def valid?(input)
      errors(input).empty?
    end

    # Símbolos e HashWithIndifferentAccess viram JSON puro, com chaves de texto.
    def normalize(input)
      JSON.parse(input.to_json)
    end

    def shape_errors(object, required:, optional:, path:)
      missing = (required - object.keys).map { |key| error("#{path}/#{key}", "required") }
      unknown = (object.keys - required - optional).map { |key| error("#{path}/#{key}", "unknown_key") }
      missing + unknown
    end

    def geo_errors(geo)
      return [ error("/geo", "not_an_object") ] unless geo.is_a?(Hash)
      return [ error("/geo/scope", "invalid_scope") ] unless GEO.key?(geo["scope"])

      scope = geo["scope"]
      found = shape_errors(geo, required: [ "scope", *GEO[scope] ], optional: [], path: "/geo")
      if scope == "unit" && geo.key?("health_unit_id") && !uuid?(geo["health_unit_id"])
        found << error("/geo/health_unit_id", "invalid_uuid")
      end
      if scope == "neighborhoods" && geo.key?("neighborhood_ids")
        found.concat(list_errors(geo["neighborhood_ids"], "/geo/neighborhood_ids", max: MAX_NEIGHBORHOODS) do |id|
          uuid?(id) ? nil : "invalid_uuid"
        end)
      end
      found
    end

    def clinical_errors(clinical)
      return [ error("/clinical", "not_an_object") ] unless clinical.is_a?(Hash)

      found = shape_errors(clinical, required: %w[all], optional: [], path: "/clinical")
      return found unless clinical.key?("all")

      all = clinical["all"]
      return found << error("/clinical/all", "not_a_list") unless all.is_a?(Array)
      return found << error("/clinical/all", "too_many") if all.size > MAX_CRITERIA

      all.each_with_index { |criterion, i| found.concat(criterion_errors(criterion, "/clinical/all/#{i}")) }
      found
    end

    def criterion_errors(criterion, path)
      return [ error(path, "not_an_object") ] unless criterion.is_a?(Hash)

      rules = CRITERIA[criterion["kind"]]
      return [ error("#{path}/kind", "invalid_kind") ] unless rules

      found = shape_errors(criterion, required: [ "kind", *rules[:required] ], optional: rules[:optional], path: path)
      (rules[:required] + rules[:optional]).each do |key|
        found.concat(field_errors(key, criterion[key], "#{path}/#{key}")) if criterion.key?(key)
      end
      found.concat(period_errors(criterion, path)) if found.empty? && criterion.key?("from")
      found
    end

    def field_errors(key, value, path)
      case key
      when "protocol_name" then text?(value, MAX_TEXT) ? [] : [ error(path, "invalid_value") ]
      when "tiers" then list_errors(value, path, max: MAX_TIERS) { |v| text?(v, 50) ? nil : "invalid_value" }
      when "outcomes"
        list_errors(value, path, max: Attendance::OUTCOMES.size) { |v| Attendance::OUTCOMES.include?(v) ? nil : "invalid_value" }
      when "kinds"
        list_errors(value, path, max: AppointmentRequest::KINDS.size) do |v|
          AppointmentRequest::KINDS.include?(v) ? nil : "invalid_value"
        end
      when "health_unit_id", "target_unit_id" then uuid?(value) ? [] : [ error(path, "invalid_uuid") ]
      when "from", "to" then date(value) ? [] : [ error(path, "invalid_date") ]
      else []
      end
    end

    def list_errors(value, path, max:)
      return [ error(path, "not_a_list") ] unless value.is_a?(Array)
      return [ error(path, "empty") ] if value.empty?
      return [ error(path, "too_many") ] if value.size > max
      return [ error(path, "duplicate") ] if value.uniq.size != value.size

      value.each_with_index.filter_map do |item, i|
        message = yield(item)
        error("#{path}/#{i}", message) if message
      end
    end

    # Datas inclusivas no fuso da cidade; "hoje" é Time.zone.today.
    def period_errors(criterion, path)
      from = date(criterion["from"])
      to = date(criterion["to"])
      return [ error("#{path}/to", "future_date") ] if to > Time.zone.today
      return [ error("#{path}/from", "inverted_period") ] if from > to

      []
    end

    def date(value)
      return nil unless value.is_a?(String) && value.match?(DATE)

      Date.iso8601(value)
    rescue Date::Error
      nil
    end

    def uuid?(value)
      value.is_a?(String) && value.match?(UUID)
    end

    def text?(value, max)
      value.is_a?(String) && value.strip.present? && value.length <= max
    end

    def error(path, message)
      { path: path, message: message }
    end
  end
end
