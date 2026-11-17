require "base64"

# "Imóveis a visitar" do agente de combate às endemias (módulo 35a, ADR 0054;
# contrato §5; Q8, Q11). Só o agente (CBO 515140, papel :field na equipe) com
# a microárea no escopo de leitura do 24b (HomeVisits::Access.reads_micro_area?):
# outro vínculo da equipe → cbo_not_allowed; fora da equipe ou da microárea →
# out_of_scope. Um item por domicílio ativo da microárea com o primeiro motivo
# que vale, nesta ordem:
#   - transmission_block: o quarteirão do perfil está na área de um bloqueio
#     `active` (o mais antigo, se houver mais de um);
#   - liraa: um item `pending` de levantamento `drawn` (o mais antigo);
#   - pending: a última situação foi closed ou refused (PENDING_SITUATIONS);
#   - due: nunca trabalhado (last_worked_on nulo) ou last_worked_on + dias da
#     cadência (VectorControl::Cadence) ≤ hoje.
# Um vínculo só por item (o do motivo; o outro sai null). Ordem: motivo, depois
# due_since (last_worked_on + dias; nulo = nunca trabalhado, primeiro, Q8),
# depois household_id. A microárea inteira é lida em consultas constantes e a
# ordem e o corte da página são feitos em Ruby (o 24b faz o mesmo no "quem
# visitar"). O cursor é a chave de ordem do último item (base64url de
# "due:<motivo>:<due_since>:<household_id>"), então a página seguinte não
# depende de o imóvel do cursor continuar na lista. Nunca morador: o imóvel
# sai com o endereço curto do 24a, e a rota grava a trilha.
module VectorControl
  module Due
    REASONS = %w[transmission_block liraa pending due].freeze
    CURSOR = /\Adue:([0-3]):(\d{4}-\d{2}-\d{2})?:(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/
    Entry = Data.define(:household_id, :property_type, :block_id, :block_number, :risk_class, :last_worked_on, :due_since,
                        :reason, :liraa_draw_item_id, :transmission_block_id) do
      def sort_key = Due.sort_key(REASONS.index(reason), due_since, household_id)
      def inspect = "#<VectorControl::Due::Entry household_id=#{household_id} reason=#{reason}>"
      alias_method :to_s, :inspect
      def pretty_print(q) = q.text(inspect)
    end
    Profile = Data.define(:risk_class)
    Place = Data.define(:property_type)

    module_function

    # -> Result.ok(items:, next_before:) | fail(:out_of_scope | :cbo_not_allowed | :invalid_cursor)
    def page(user:, team:, micro_area:, before:, limit:, today:)
      refusal = access(user, team, micro_area)
      return Result.fail(refusal) if refusal

      after = before.nil? ? nil : decode_cursor(before)
      return Result.fail(:invalid_cursor) if after == :invalid

      rows = entries(micro_area, today).sort_by(&:sort_key)
      rows = rows.select { |entry| (entry.sort_key <=> after) == 1 } if after
      shown = rows.first(limit)
      next_before = rows.size > limit ? encode_cursor(shown.last) : nil
      Result.ok(items: items(shown), next_before: next_before)
    end

    def access(user, team, micro_area)
      member = HomeVisits::Access.member(user, team)
      return :out_of_scope unless member && micro_area.team_id == team.id
      return :cbo_not_allowed unless VectorControl::Access.field_agent?(user, team)
      return :out_of_scope unless HomeVisits::Access.reads_micro_area?(user, micro_area)

      nil
    end

    # [Entry] dos domicílios ativos da microárea que têm motivo, sem ordem.
    def entries(micro_area, today)
      households = HouseholdVersion.joins(:household)
                                   .where(households: { micro_area_id: micro_area.id, status: "active" })
                                   .where("household_versions.version = households.version")
                                   .pluck(:household_id, :property_type, :neighborhood_id)
      return [] if households.empty?

      ids = households.map(&:first)
      profiles = HouseholdVectorProfile.left_joins(:city_block).where(household_id: ids)
                                       .pluck(:household_id, :city_block_id, "city_blocks.number", :risk_class, :last_worked_on, :last_situation)
                                       .index_by(&:first)
      blocks = transmission_blocks(profiles.values.filter_map { |row| row[1] }.uniq)
      liraa = liraa_items(ids)
      table = Cadence.table
      parameters = Parameters.current.values
      households.filter_map do |household_id, property_type, neighborhood_id|
        _, block_id, block_number, risk, last_worked_on, last_situation = profiles[household_id]
        days = Cadence.days_for(profile: Profile.new(risk_class: risk), household: Place.new(property_type: property_type),
                                neighborhood_id: neighborhood_id, table: table, parameters: parameters)
        due_since = last_worked_on && last_worked_on + days
        transmission_block_id = block_id && blocks[block_id]
        liraa_draw_item_id = liraa[household_id] unless transmission_block_id
        reason = if transmission_block_id then "transmission_block"
                 elsif liraa_draw_item_id then "liraa"
                 elsif Catalog::PENDING_SITUATIONS.include?(last_situation) then "pending"
                 elsif due_since.nil? || due_since <= today then "due"
                 end
        next unless reason

        Entry.new(household_id: household_id, property_type: property_type, block_id: block_id, block_number: block_number,
                  risk_class: risk, last_worked_on: last_worked_on, due_since: due_since, reason: reason,
                  liraa_draw_item_id: liraa_draw_item_id, transmission_block_id: transmission_block_id)
      end
    end

    # { city_block_id => transmission_block_id } do bloqueio ativo mais antigo.
    def transmission_blocks(block_ids)
      return {} if block_ids.empty?

      TransmissionBlockArea.joins(:transmission_block).where(city_block_id: block_ids, transmission_blocks: { status: "active" })
                           .order("transmission_blocks.created_at", "transmission_blocks.id")
                           .pluck(:city_block_id, :transmission_block_id)
                           .each_with_object({}) { |(block_id, id), map| map[block_id] ||= id }
    end

    # { household_id => liraa_draw_item_id } do item pendente mais antigo de levantamento sorteado.
    def liraa_items(household_ids)
      LiraaDrawItem.joins(liraa_stratum: :liraa_survey)
                   .where(household_id: household_ids, status: "pending", liraa_surveys: { status: "drawn" })
                   .order("liraa_draw_items.created_at", "liraa_draw_items.id")
                   .pluck(:household_id, :id)
                   .each_with_object({}) { |(household_id, id), map| map[household_id] ||= id }
    end

    def items(entries)
      addresses = HomeVisits::Json.addresses(entries.map(&:household_id))
      entries.map do |entry|
        { household_id: entry.household_id, address_short: addresses.fetch(entry.household_id), property_type: entry.property_type,
          block: entry.block_id && { id: entry.block_id, number: entry.block_number }, risk_class: entry.risk_class,
          last_worked_on: entry.last_worked_on&.iso8601, due_since: entry.due_since&.iso8601, reason: entry.reason,
          liraa_draw_item_id: entry.liraa_draw_item_id, transmission_block_id: entry.transmission_block_id }
      end
    end

    # Nulo (nunca trabalhado) antes de qualquer data.
    def sort_key(rank, due_since, household_id) = [ rank, due_since ? 1 : 0, due_since&.jd || 0, household_id ]

    def encode_cursor(entry)
      Base64.urlsafe_encode64("due:#{REASONS.index(entry.reason)}:#{entry.due_since&.iso8601}:#{entry.household_id}", padding: false)
    end

    # A chave de ordem do cursor, ou :invalid.
    def decode_cursor(raw)
      return :invalid unless raw.is_a?(String) && !raw.empty?

      match = Base64.urlsafe_decode64(raw).match(CURSOR)
      return :invalid unless match

      sort_key(Integer(match[1]), match[2] && Date.iso8601(match[2]), match[3].downcase)
    rescue ArgumentError, EncodingError, Date::Error
      :invalid
    end
  end
end
