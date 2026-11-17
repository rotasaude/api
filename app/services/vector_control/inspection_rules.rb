# Regras puras do boletim do agente de endemias na visita (módulo 35a, ADR
# 0054; contrato §3, Q7(3)(4)(7), Q9, Q10, Q13; plano, W-1, A-3, A-10). Quem
# chama (HomeVisits::Record) passa os fatos já lidos e travados: nenhuma
# consulta ao banco aqui.
#
# `check` devolve [] ou [{ error:, path: }] com o PRIMEIRO problema (Q13), na
# ordem do contrato — a mesma do `checkInspection` do dashboard, cuja lista
# completa começa por este erro. Os `path` são os da tabela da Task 2 do plano
# do dashboard (Q9). Ordem:
#   1. gate (feature_disabled) e CBO (cbo_not_allowed), path vector_inspection;
#      sem domicílio → vector_inspection_invalid path household_id (A-10);
#   forma do boletim (Q7(4)(7)): objeto, chaves conhecidas, as obrigatórias,
#      domínios, tipos e listas → vector_inspection_invalid com o path do campo
#      (faixas de contagem, carga e larvas e o tamanho das listas ficam na
#      regra de cada uma, como no dashboard);
#   2. situação × desfecho; não trabalhado sem depósito, medida, amostra e ação;
#   3. atividade × tipo de imóvel;
#   4. vínculos (LIRAa, bloqueio; vínculo fora da atividade dele);
#   5. depósitos; 6. medidas; 7. amostras; 8. horários;
#   9. motivos derivados no corpo (reason_derived, path reasons);
#  10. quarteirão no boletim.
# Nunca o valor no erro: só código e path.
module VectorControl
  module InspectionRules
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    INSTANT = HomeVisits::Record::INSTANT
    KEY_PATH_MAX = 64
    ROOT = "vector_inspection".freeze
    KEYS = %w[
      activity work_type situation educational_action entered_at left_at city_block_id risk_class liraa_draw_item_id
      transmission_block_id deposits measures samples
    ].freeze
    ID_KEYS = %w[city_block_id liraa_draw_item_id transmission_block_id].freeze
    LISTS = %w[deposits measures samples].freeze
    DEPOSIT_KEYS = ([ "group" ] + Catalog::DEPOSIT_FIELDS).freeze
    MEASURE_KEYS = %w[method vector_product_id charges].freeze
    SAMPLE_KEYS = %w[number deposit_group larvae_collected].freeze
    # Desigualdades do §3.5, na ordem dos campos: campo ≤ teto.
    DEPOSIT_CEILINGS = { "with_water" => "existing", "with_larvae" => "with_water", "eliminated" => "existing",
                         "treated" => "with_water" }.freeze

    module Opaque
      def inspect = "#<#{self.class.name}>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    # Os fatos lidos pelo HomeVisits::Record (W-1), mais `city_block` (o
    # quarteirão citado em `vector_inspection.city_block_id`, lido FOR SHARE:
    # `{ id, neighborhood_id, active }` | nil), que a regra 10 pede e a W-1 não
    # listava. `liraa_item` = `{ id, household_id, status, survey_status }` |
    # nil; `transmission_block` = `{ id, status, area_block_ids }` | nil;
    # `products` = `{ id => { active, uses, unit, charge_size } }`.
    Facts = Data.define(:usable, :cbo, :outcome, :property_type, :occurred_at, :profile_block_id, :liraa_item,
                        :transmission_block, :products, :city_block) { include Opaque }

    module_function

    # `input` = o `vector_inspection` do corpo; `visit` = o corpo da visita
    # (chaves texto; lê `reasons`); `household` = `{ id:, neighborhood_id: }` |
    # nil; `profile` = `{ city_block_id: }` | nil (perfil travado); `today` é o
    # dia da cidade (assinatura do §3; os horários valem pelo dia da visita).
    def check(input, visit:, household:, profile:, today:, facts:)
      _ = today
      error = access(facts) || (err(:vector_inspection_invalid, "household_id") if household.nil?) || shape(input) ||
              situation(input, facts) || activity(input, facts) || links(input, household, profile, facts) ||
              deposits(input) || measures(input, facts) || samples(input) || times(input, facts) ||
              reasons(visit) || block(input, household, profile, facts)
      error ? [ error ] : []
    end

    # Motivos 34–37 pelo boletim (§3.9), em união crescente com os do corpo.
    # Corpo sem lista de inteiros fica como veio (as regras do 24b recusam).
    def derived_reasons(reasons, input)
      reasons = [] if reasons.nil?
      return reasons unless reasons.is_a?(Array) && reasons.all?(Integer)

      (reasons + derived(input).reject { |code| reasons.include?(code) }).sort
    end

    # Os derivados sozinhos, crescentes.
    def derived(input)
      deposits = list(input, "deposits")
      methods = list(input, "measures").map { |measure| measure["method"] }
      codes = []
      codes << 34 if input["educational_action"] == true
      codes << 35 if deposits.any? { |deposit| positive?(deposit["with_larvae"]) }
      codes << 36 if deposits.any? { |deposit| positive?(deposit["eliminated"]) } || methods.include?("mechanical")
      codes << 37 if methods.include?("focal")
      codes
    end

    # Quantidade da baixa (A-2): cargas × carga do produto, teto em 2 casas
    # (mínimo 0,01, já que as duas são positivas).
    def quantity(charges, charge_size) = (BigDecimal(charges.to_s) * BigDecimal(charge_size.to_s)).ceil(2)

    # Etiqueta da amostra (§9): os 8 primeiros do client_uuid da visita em
    # maiúsculas, hífen e o número com 2 dígitos.
    def label(client_uuid, number) = "#{client_uuid[0, 8].upcase}-#{format('%02d', number)}"

    # 1. ----------------------------------------------------------------------

    def access(facts)
      return err(:feature_disabled, ROOT) unless facts.usable
      return err(:cbo_not_allowed, ROOT) unless facts.cbo == TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO

      nil
    end

    # Forma (Q7(7)) ------------------------------------------------------------

    def shape(input)
      return err(:vector_inspection_invalid, ROOT) unless input.is_a?(Hash)

      unknown = (input.keys - KEYS).first
      return invalid("#{ROOT}.#{unknown}") if unknown

      missing = Catalog::REQUIRED_KEYS.find { |key| !input.key?(key) }
      return invalid("#{ROOT}.#{missing}") if missing

      domains = { "activity" => Catalog::ACTIVITIES, "work_type" => Catalog::WORK_TYPES, "situation" => Catalog::SITUATIONS }
      domains.each { |key, values| return invalid("#{ROOT}.#{key}") unless values.include?(input[key]) }
      return invalid("#{ROOT}.educational_action") unless [ true, false ].include?(input["educational_action"])

      %w[entered_at left_at].each { |key| return invalid("#{ROOT}.#{key}") if input.key?(key) && instant(input[key]).nil? }
      ID_KEYS.each { |key| return invalid("#{ROOT}.#{key}") if input.key?(key) && !uuid?(input[key]) }
      return invalid("#{ROOT}.risk_class") if input.key?("risk_class") && !Catalog::RISK_CLASSES.include?(input["risk_class"])

      LISTS.each { |key| return invalid("#{ROOT}.#{key}") if input.key?(key) && !input[key].is_a?(Array) }
      items_shape(input, "deposits", DEPOSIT_KEYS, DEPOSIT_KEYS) { |deposit, path| deposit_shape(deposit, path) } ||
        items_shape(input, "measures", MEASURE_KEYS, %w[method]) { |measure, path| measure_shape(measure, path) } ||
        items_shape(input, "samples", SAMPLE_KEYS, SAMPLE_KEYS) { |sample, path| sample_shape(sample, path) }
    end

    def items_shape(input, key, known, required)
      list(input, key).each_with_index do |item, index|
        path = "#{ROOT}.#{key}[#{index}]"
        return invalid(path) unless item.is_a?(Hash)

        unknown = (item.keys - known).first
        return invalid("#{path}.#{unknown}") if unknown

        missing = required.find { |field| !item.key?(field) }
        return invalid("#{path}.#{missing}") if missing

        error = yield(item, path)
        return error if error
      end
      nil
    end

    def deposit_shape(deposit, path)
      invalid("#{path}.group") unless Catalog::DEPOSIT_GROUPS.include?(deposit["group"])
    end

    def measure_shape(measure, path)
      return invalid("#{path}.method") unless Catalog::METHODS.include?(measure["method"])

      invalid("#{path}.vector_product_id") if measure.key?("vector_product_id") && !uuid?(measure["vector_product_id"])
    end

    def sample_shape(sample, path)
      return invalid("#{path}.number") unless sample["number"].is_a?(Integer)
      return invalid("#{path}.deposit_group") unless Catalog::DEPOSIT_GROUPS.include?(sample["deposit_group"])

      invalid("#{path}.larvae_collected") unless sample["larvae_collected"].is_a?(Integer)
    end

    # 2. Situação e desfecho ---------------------------------------------------

    def situation(input, facts)
      # Desfecho fora do domínio: as regras do 24b recusam (invalid_home_visit).
      return nil unless HomeVisits::Catalog::OUTCOMES.key?(facts.outcome)
      return err(:situation_outcome_mismatch, "#{ROOT}.situation") if Catalog::SITUATION_OUTCOME.fetch(input["situation"]) != facts.outcome
      return nil if input["situation"] == "worked"

      filled = LISTS.find { |key| list(input, key).any? }
      return err(:inspection_not_worked, "#{ROOT}.#{filled}") if filled

      err(:inspection_not_worked, "#{ROOT}.educational_action") if input["educational_action"]
    end

    # 3. Atividade e imóvel ----------------------------------------------------

    def activity(input, facts)
      allowed = case input["activity"]
                when "pe" then [ Catalog::PE_PROPERTY ]
                when "ie" then Catalog::IE_PROPERTIES
                end
      err(:activity_property_mismatch, "#{ROOT}.activity") if allowed && !allowed.include?(facts.property_type)
    end

    # 4. Vínculos --------------------------------------------------------------

    def links(input, household, profile, facts)
      own = Catalog::LINKED_ACTIVITIES[input["activity"]]
      case input["activity"]
      when "liraa"
        item = facts.liraa_item
        unless input[own] && item && item[:id] == id(input[own]) && item[:household_id] == household[:id] &&
               item[:status] == "pending" && item[:survey_status] == "drawn"
          return err(:liraa_item_not_found, "#{ROOT}.#{own}")
        end
      when "transmission_block"
        block = facts.transmission_block
        block_id = profile&.dig(:city_block_id) || id(input["city_block_id"])
        unless input[own] && block && block[:id] == id(input[own]) && block[:status] == "active" &&
               block_id && block[:area_block_ids].include?(block_id)
          return err(:transmission_block_not_active, "#{ROOT}.#{own}")
        end
      end
      foreign = Catalog::LINKED_ACTIVITIES.values.find { |key| key != own && input.key?(key) }
      invalid("#{ROOT}.#{foreign}") if foreign
    end

    # 5. Depósitos -------------------------------------------------------------

    def deposits(input)
      deposits = list(input, "deposits")
      return invalid("#{ROOT}.deposits") if deposits.size > Catalog::DEPOSIT_GROUPS.size

      deposits.each_with_index do |deposit, index|
        path = "#{ROOT}.deposits[#{index}]"
        field = Catalog::DEPOSIT_FIELDS.find { |key| !count?(deposit[key]) }
        return invalid("#{path}.#{field}") if field

        field = DEPOSIT_CEILINGS.find { |key, ceiling| deposit[key] > deposit[ceiling] }&.first
        return err(:deposit_counts_inconsistent, "#{path}.#{field}") if field

        repeated = deposits.index { |other| other["group"] == deposit["group"] } != index
        return err(:deposit_counts_inconsistent, "#{path}.group") if repeated
      end
      nil
    end

    # 6. Medidas ---------------------------------------------------------------

    def measures(input, facts)
      measures = list(input, "measures")
      return invalid("#{ROOT}.measures") if measures.size > Catalog::LIMITS.fetch(:measures_max)

      measures.each_with_index do |measure, index|
        path = "#{ROOT}.measures[#{index}]"
        error = measure["method"] == "mechanical" ? mechanical(measure, path) : chemical(measure, path, facts)
        return error if error

        key = [ measure["method"], id(measure["vector_product_id"]) ]
        return invalid(path) if measures.index { |other| [ other["method"], id(other["vector_product_id"]) ] == key } != index
      end
      nil
    end

    def mechanical(measure, path)
      return invalid("#{path}.vector_product_id") if measure.key?("vector_product_id")

      invalid("#{path}.charges") if measure.key?("charges")
    end

    def chemical(measure, path, facts)
      product = facts.products[id(measure["vector_product_id"])]
      unless product && product[:active] && product[:uses].include?(measure["method"])
        return err(:product_not_allowed, "#{path}.vector_product_id")
      end

      invalid("#{path}.charges") unless charges?(measure["charges"])
    end

    # 7. Amostras --------------------------------------------------------------

    def samples(input)
      samples = list(input, "samples")
      return invalid("#{ROOT}.samples") if samples.size > Catalog::LIMITS.fetch(:samples_max)

      larvae = list(input, "deposits").to_h { |deposit| [ deposit["group"], deposit["with_larvae"] ] }
      numbers = samples.map { |sample| sample["number"] }
      samples.each_with_index do |sample, index|
        path = "#{ROOT}.samples[#{index}]"
        # De 1 a N sem buraco: N números distintos dentro de 1..N.
        number = sample["number"]
        return err(:samples_exceed_larvae, path) unless number.between?(1, samples.size) && numbers.index(number) == index

        group = sample["deposit_group"]
        position = samples.first(index + 1).count { |other| other["deposit_group"] == group }
        return err(:samples_exceed_larvae, path) unless position <= larvae.fetch(group, 0)
        return invalid("#{path}.larvae_collected") unless Catalog::LARVAE.cover?(sample["larvae_collected"])
      end
      nil
    end

    # 8. Horários --------------------------------------------------------------

    def times(input, facts)
      return nil unless input.key?("entered_at") || input.key?("left_at")

      bad = err(:inspection_times_invalid, "#{ROOT}.entered_at")
      return bad unless input.key?("entered_at") && input.key?("left_at")

      # Visita sem instante válido: as regras do 24b recusam occurred_at.
      occurred = facts.occurred_at
      return nil if occurred.nil?

      entered = instant(input["entered_at"])
      left = instant(input["left_at"])
      day = occurred.in_time_zone.to_date
      return bad unless entered <= occurred && occurred <= left && left - entered <= Catalog::INSPECTION_MAX.to_i
      return bad unless entered.to_date == day && left.to_date == day

      nil
    end

    # 9. Motivos derivados no corpo -------------------------------------------

    def reasons(visit)
      body = visit["reasons"]
      err(:reason_derived, "reasons") if body.is_a?(Array) && body.intersect?(Catalog::DERIVED_REASONS)
    end

    # 10. Quarteirão no boletim (§2) -------------------------------------------

    def block(input, household, profile, facts)
      return nil unless input.key?("city_block_id")

      path = "#{ROOT}.city_block_id"
      return err(:block_already_set, path) if profile&.dig(:city_block_id)

      block = facts.city_block
      return invalid(path) unless block && block[:id] == id(input["city_block_id"]) && block[:active]
      return err(:household_without_neighborhood, path) if household[:neighborhood_id].nil?

      err(:block_not_in_household_neighborhood, path) if block[:neighborhood_id] != household[:neighborhood_id]
    end

    # --- apoio ----------------------------------------------------------------

    def list(input, key)
      value = input.is_a?(Hash) ? input[key] : nil
      value.is_a?(Array) ? value : []
    end

    def count?(value) = value.is_a?(Integer) && value.between?(0, Catalog::DEPOSIT_MAX)

    # (0, 999], com no máximo duas casas.
    def charges?(value)
      return false unless value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)

      decimal = BigDecimal(value.to_s)
      decimal.positive? && decimal <= Catalog::LIMITS.fetch(:charges_max) && (decimal * 100).frac.zero?
    end

    def positive?(value) = value.is_a?(Integer) && value.positive?

    def instant(value)
      return nil unless value.is_a?(String) && value.match?(INSTANT)

      Time.iso8601(value).in_time_zone
    rescue ArgumentError
      nil
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    # Ids do corpo comparados com os do banco (uuid em minúsculas).
    def id(value) = value.is_a?(String) ? value.downcase : nil
    def invalid(path) = err(:vector_inspection_invalid, path[0, KEY_PATH_MAX])
    def err(code, path) = { error: code, path: path }
    private_class_method :access, :shape, :items_shape, :deposit_shape, :measure_shape, :sample_shape, :situation, :activity,
                         :links, :deposits, :measures, :mechanical, :chemical, :samples, :times, :reasons, :block, :list,
                         :count?, :charges?, :positive?, :instant, :uuid?, :id, :invalid, :err
  end
end
