# O bloco `dental` do rascunho (ADR 0046; contrato §2, §6, §16 O2, O5, O6,
# O25; Desvios 3, 6): <dental_fields> → colunas escalares da FAO (`attrs`) e
# os itens que ficam em draft_items["dental"] (`items`). Só as chaves
# presentes mudam. Códigos da FAO e dente chegam inteiros ou string de
# dígitos e ficam inteiros. Cada procedimento: SIGTAP que a FAO aceita e
# compatível na release da competência (CBO, idade, sexo), local pelo
# Location e casado com a lista do LEDI; quantidade 1, salvo sextante, arcada
# ou boca com `quantity` explícito. O `id` do procedimento nasce aqui (uuid) e
# o que o cliente devolve fica. A primeira recusa, com o `path` do corpo
# (`dental.procedures[2].location`); nunca o valor (dado clínico). Os limites
# por consulta, o plano e o papel do autor são da finalização (Requirements).
module DentalCare
  module DraftInput
    COLUMNS = %w[care_type dental_consultation_type oral_health_surveillance supplies dental_outcomes pregnant special_needs].freeze
    ITEMS = %w[procedures findings plan_changes periodontal_screening periodontal_chart endodontics].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    SIGTAP = /\A\d{10}\z/
    INTEGER = /\A-?\d+\z/
    MAX_QUANTITY = 32

    class Refused < StandardError
      attr_reader :reason, :details

      def initialize(reason, details)
        @reason = reason
        @details = details
        super(reason.to_s)
      end
    end

    module_function

    def call(raw, consultation:, on: Time.zone.today)
      raw = normalize(raw)
      refuse!(:invalid_request, "dental") unless raw.is_a?(Hash)

      context = { consultation: consultation, patient: consultation.patient, on: on }
      attrs = columns(raw)
      items = ITEMS.select { |key| raw.key?(key) }.to_h { |key| [ key, send(key, raw[key], context) ] }
      Result.ok(attrs: attrs, items: items)
    rescue Refused => e
      Result.fail(e.reason, details: e.details)
    end

    def columns(raw)
      attrs = {}
      if raw.key?("care_type")
        attrs["care_type"] = optional_code(raw["care_type"], Catalog::CARE_TYPES, "dental.care_type", reason: :invalid_care_type)
      end
      if raw.key?("dental_consultation_type")
        attrs["dental_consultation_type"] = optional_code(raw["dental_consultation_type"], Catalog::CONSULTATION_TYPES,
                                                          "dental.dental_consultation_type")
      end
      { "oral_health_surveillance" => Catalog::SURVEILLANCE, "supplies" => Catalog::SUPPLIES, "dental_outcomes" => Catalog::OUTCOMES }
        .each { |key, allowed| attrs[key] = code_list(raw[key], allowed, "dental.#{key}") if raw.key?(key) }
      if raw.key?("pregnant")
        refuse!(:invalid_request, "dental.pregnant") unless [ true, false, nil ].include?(raw["pregnant"])
        attrs["pregnant"] = raw["pregnant"]
      end
      if raw.key?("special_needs")
        refuse!(:invalid_request, "dental.special_needs") unless [ true, false ].include?(raw["special_needs"])
        attrs["special_needs"] = raw["special_needs"]
      end
      attrs
    end

    def procedures(list, context)
      path = "dental.procedures"
      array!(list, path, max: Catalog::MAX_ITEMS).each_with_index.map do |raw, index|
        at = "#{path}[#{index}]"
        hash!(raw, at)
        id = raw["id"].nil? ? SecureRandom.uuid : raw["id"]
        refuse!(:invalid_request, "#{at}.id") unless id.is_a?(String) && id.match?(UUID)

        sigtap, location = procedure_at(raw, at, context)
        { "id" => id.downcase, "sigtap" => sigtap, "location" => location, "quantity" => quantity(raw, location, at),
          "plan_item_id" => uuid_or_nil(raw["plan_item_id"], "#{at}.plan_item_id"),
          "prosthesis_order_id" => prosthesis_order(raw["prosthesis_order_id"], "#{at}.prosthesis_order_id", context) }
      end
    end

    # Achado num dente (coroa com ou sem face, ou raiz) ou numa arcada
    # (complete_denture; vira um evento por dente na finalização).
    def findings(list, _context)
      path = "dental.findings"
      array!(list, path, max: Catalog::MAX_ITEMS).each_with_index.map do |raw, index|
        at = "#{path}[#{index}]"
        hash!(raw, at)
        unless raw["arch"].nil?
          refuse!(:invalid_request, "#{at}.arch") unless Catalog::ARCHES.include?(raw["arch"]) && raw["tooth"].nil? && raw["face"].nil?
          reason = Situations.reason(raw["situation"], part: "arch", tooth: nil)
          refuse!(reason, "#{at}.situation") if reason
          next({ "tooth" => nil, "face" => nil, "part" => nil, "arch" => raw["arch"], "situation" => raw["situation"] })
        end

        tooth = tooth!(raw["tooth"], "#{at}.tooth")
        part = raw["part"].nil? ? "crown" : raw["part"]
        refuse!(:invalid_request, "#{at}.part") unless Catalog::PARTS.include?(part)
        face = raw["face"]
        refuse!(:invalid_request, "#{at}.face") unless face.nil? || Catalog::FACES.include?(face)
        reason = Situations.reason(raw["situation"], part: part, tooth: tooth, face: face)
        refuse!(reason, "#{at}.situation") if reason

        { "tooth" => tooth, "face" => face, "part" => part, "arch" => nil, "situation" => raw["situation"] }
      end
    end

    def plan_changes(raw, context)
      path = "dental.plan_changes"
      raw = normalize(raw)
      hash!(raw, path)
      add = array!(raw.fetch("add", []), "#{path}.add", max: Catalog::MAX_ITEMS).each_with_index.map do |item, index|
        at = "#{path}.add[#{index}]"
        hash!(item, at)
        sigtap, location = procedure_at(item, at, context)
        { "sigtap" => sigtap, "location" => location }
      end
      cancel = array!(raw.fetch("cancel", []), "#{path}.cancel", max: Catalog::MAX_ITEMS).each_with_index.map do |item, index|
        at = "#{path}.cancel[#{index}]"
        hash!(item, at)
        refuse!(:invalid_request, "#{at}.item_id") unless item["item_id"].is_a?(String) && item["item_id"].match?(UUID)

        { "item_id" => item["item_id"].downcase, "reason" => reason!(item["reason"], "#{at}.reason") }
      end
      refuse!(:invalid_request, "#{path}.cancel") unless cancel.map { |c| c["item_id"] }.uniq.size == cancel.size
      cancel_plan = raw["cancel_plan"]
      unless cancel_plan.nil?
        cancel_plan = normalize(cancel_plan)
        hash!(cancel_plan, "#{path}.cancel_plan")
        cancel_plan = { "reason" => reason!(cancel_plan["reason"], "#{path}.cancel_plan.reason") }
      end
      { "add" => add, "cancel" => cancel, "cancel_plan" => cancel_plan }
    end

    # Registro periodontal simplificado: código 0..4 por sextante (nulo = "X").
    def periodontal_screening(raw, _context)
      path = "dental.periodontal_screening"
      return nil if raw.nil?

      raw = normalize(raw)
      hash!(raw, path)
      sextants = array!(raw["sextants"], "#{path}.sextants", max: Catalog::SEXTANTS.size).each_with_index.map do |item, index|
        at = "#{path}.sextants[#{index}]"
        hash!(item, at)
        refuse!(:invalid_request, "#{at}.sextant") unless Catalog::SEXTANTS.include?(item["sextant"])

        { "sextant" => item["sextant"], "code" => optional_int(item["code"], Catalog::SCREENING_CODES, "#{at}.code"),
          "star" => bool(item.fetch("star", false), "#{at}.star") }
      end
      refuse!(:invalid_request, "#{path}.sextants") unless sextants.map { |s| s["sextant"] }.uniq.size == sextants.size
      { "sextants" => sextants }
    end

    def periodontal_chart(raw, _context)
      path = "dental.periodontal_chart"
      return nil if raw.nil?

      raw = normalize(raw)
      hash!(raw, path)
      teeth = array!(raw["teeth"], "#{path}.teeth", max: Location::TEETH.size).each_with_index.map do |item, index|
        at = "#{path}.teeth[#{index}]"
        hash!(item, at)
        { "tooth" => tooth!(item["tooth"], "#{at}.tooth"),
          "mobility" => optional_int(item["mobility"], Catalog::MOBILITY, "#{at}.mobility"),
          "furcation" => optional_int(item["furcation"], Catalog::FURCATION, "#{at}.furcation"),
          "sites" => sites(item["sites"], "#{at}.sites") }
      end
      refuse!(:invalid_request, "#{path}.teeth") unless teeth.map { |t| t["tooth"] }.uniq.size == teeth.size
      { "teeth" => teeth }
    end

    def endodontics(list, _context)
      path = "dental.endodontics"
      entries = array!(list, path, max: Location::TEETH.size).each_with_index.map do |item, index|
        at = "#{path}[#{index}]"
        hash!(item, at)
        refuse!(:invalid_request, "#{at}.status") unless Catalog::ENDO_STATUSES.include?(item["status"])

        { "tooth" => tooth!(item["tooth"], "#{at}.tooth"), "canals" => int!(item["canals"], Catalog::CANALS, "#{at}.canals"),
          "status" => item["status"] }
      end
      refuse!(:invalid_request, path) unless entries.map { |e| e["tooth"] }.uniq.size == entries.size
      entries
    end

    def sites(list, path)
      sites = array!(list, path, max: Catalog::PERIO_SITES.size).each_with_index.map do |item, index|
        at = "#{path}[#{index}]"
        hash!(item, at)
        refuse!(:invalid_request, "#{at}.site") unless Catalog::PERIO_SITES.include?(item["site"])

        { "site" => item["site"], "probing_depth_mm" => int!(item["probing_depth_mm"], Catalog::PROBING_MM, "#{at}.probing_depth_mm"),
          "recession_mm" => int!(item["recession_mm"], Catalog::RECESSION_MM, "#{at}.recession_mm"),
          "bleeding" => bool(item.fetch("bleeding", false), "#{at}.bleeding") }
      end
      refuse!(:invalid_request, path) unless sites.map { |s| s["site"] }.uniq.size == sites.size
      sites
    end

    # [sigtap, location (chaves string, dente inteiro)] do procedimento ou do item do plano.
    def procedure_at(raw, at, context)
      sigtap = raw["sigtap"]
      refuse!(:invalid_procedure, "#{at}.sigtap", reasons: %w[unknown_procedure]) unless sigtap.is_a?(String) && sigtap.match?(SIGTAP)
      refuse!(:invalid_procedure, "#{at}.sigtap", reasons: %w[not_allowed_on_fao]) unless ProcedureSearch.searchable?(sigtap)

      patient = context[:patient]
      check = Terminology::Sigtap.compatible?(sigtap, competence: context[:on].strftime("%Y%m"), cbo: context[:consultation].cbo_code,
                                                      age_months: age_months(patient.birth_date, context[:on]), sex: patient.sex)
      refuse!(:invalid_procedure, "#{at}.sigtap", reasons: check[:reasons]) unless check[:ok]

      parsed = Location.parse(normalize(raw["location"]))
      refuse!(:invalid_location, "#{at}.location") if parsed.failure?

      location = parsed.payload[:location]
      refuse!(:invalid_location, "#{at}.location") unless ProcedureLimits.location_ok?(sigtap, location[:kind])

      [ sigtap, location.transform_keys(&:to_s) ]
    end

    def quantity(raw, location, at)
      return 1 if raw["quantity"].nil?
      return int!(raw["quantity"], 1..MAX_QUANTITY, "#{at}.quantity") if %w[sextant arch mouth].include?(location["kind"])

      refuse!(:invalid_request, "#{at}.quantity") unless raw["quantity"] == 1
      1
    end

    # Task 6 só guarda o pedido (do paciente); as etapas e a instalação são da Task 11.
    def prosthesis_order(value, path, context)
      id = uuid_or_nil(value, path)
      refuse!(:invalid_request, path) if id && !DentalProsthesisOrder.exists?(id: id, patient_id: context[:patient].id)
      id
    end

    def code_list(list, allowed, path)
      array!(list, path, max: allowed.size)
      seen = []
      list.each_with_index.map do |value, index|
        code = Ledi::ConsultationMapping.code(value)
        refuse!(:invalid_request, "#{path}[#{index}]") unless allowed.include?(code) && !seen.include?(code)

        seen << code
        code
      end
    end

    def optional_code(value, allowed, path, reason: :invalid_request)
      return nil if value.nil?

      code = Ledi::ConsultationMapping.code(value)
      refuse!(reason, path) unless allowed.include?(code)
      code
    end

    def tooth!(value, path)
      code = Ledi::ConsultationMapping.code(value)
      refuse!(:invalid_request, path) unless Location::TEETH.include?(code)
      code
    end

    def int!(value, range, path)
      number = case value
               when Integer then value
               when String then value.match?(INTEGER) ? value.to_i : nil
               end
      refuse!(:invalid_request, path) unless number && range.cover?(number)
      number
    end

    def optional_int(value, range, path) = value.nil? ? nil : int!(value, range, path)

    def bool(value, path)
      refuse!(:invalid_request, path) unless [ true, false ].include?(value)
      value
    end

    def uuid_or_nil(value, path)
      return nil if value.nil?

      refuse!(:invalid_request, path) unless value.is_a?(String) && value.match?(UUID)
      value.downcase
    end

    def reason!(value, path)
      text = value.is_a?(String) ? value.strip : nil
      refuse!(:invalid_reason, path) unless text && Catalog::REASON.cover?(text.length)
      text
    end

    def array!(list, path, max:)
      refuse!(:invalid_request, path) unless list.is_a?(Array) && list.size <= max
      list.map { |item| normalize(item) }
    end

    def hash!(value, path)
      refuse!(:invalid_request, path) unless value.is_a?(Hash)
    end

    def age_months(birth_date, on)
      born = Date.iso8601(birth_date.to_s)
      months = (on.year * 12 + on.month) - (born.year * 12 + born.month)
      on.day < born.day ? months - 1 : months
    rescue Date::Error
      nil
    end

    def normalize(value)
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      value.is_a?(Hash) ? value.deep_stringify_keys : value
    end

    def refuse!(reason, path, **extra) = raise(Refused.new(reason, { path: path, **extra }))
    private_class_method :columns, :procedures, :findings, :plan_changes, :periodontal_screening, :periodontal_chart, :endodontics,
                         :sites, :procedure_at, :quantity, :prosthesis_order, :code_list, :optional_code, :tooth!, :int!,
                         :optional_int, :bool, :uuid_or_nil, :reason!, :array!, :hash!, :age_months, :normalize, :refuse!
  end
end
