# Relatórios da vigilância ambiental (módulo 35a, ADR 0054; contrato §10;
# Q8: a forma VectorReport da Task 1 do plano do dashboard). Uma forma para os
# sete (Catalog::REPORTS):
#   { name, provisional? (só o liraa), columns: [{ key, label, kind }], rows, notes? }
# `kind` ∈ text count percent decimal. Contagem é inteiro (ou
# Admin::SmallCount::SUPPRESSED, só nos casos do `blocks`); percentual e
# decimal são texto (uma casa; duas nas quantidades do consumo), como os
# decimais do 27a; nil sem denominador.
#
# Filtros (`filters` = a query, chaves em texto; quem chama já recusou chave
# fora de FILTERS): inválido → Result.fail(:invalid_request, path:), com o
# path da chave (`epi_weeks[i]`, `neighborhood_ids[i]`, `professional_ids[i]`,
# `cycle_id`, `survey_id`, `from`, `to`). Id que não existe também é filtro
# inválido. Sem bairros na query: os bairros ativos, por nome.
#
# Tudo agregado no banco, com um número constante de consultas por
# relatório; nunca inspeção a inspeção. Só contagens: nenhum imóvel, nome,
# CPF, CNS, telefone ou endereço de pessoa; caso só como contagem. Sem trilha.
#   - situations (cycle_id, neighborhood_ids[]): por classe de imóvel
#     (Catalog::PROPERTY_CLASSES) e por bairro (a cobertura), os números do
#     CycleStats;
#   - strategic_points (cycle_id): os PE (tipo 4) ativos em microárea ativa
#     pela quinzena (1–15, 16–fim do mês) da última visita válida do ciclo e
#     pela situação dela; os sem visita; o total;
#   - production (from, to, professional_ids[]): por agente (a folha da
#     visita) e dia da visita: imóveis, trabalhados, depósitos eliminados e
#     tratados, amostras e cargas por produto;
#   - consumption (from, to): por produto, das visitas do período: cargas e
#     quantidade (visitas válidas), baixa líquida no estoque (aplicação menos
#     estorno) e faltas por causa;
#   - ovitraps (epi_weeks[], neighborhood_ids[]): OvitrapIndex por bairro e
#     semana;
#   - liraa (survey_id): Liraa::Index por estrato e do município, com
#     `provisional` (e a coluna "Provisório" sim/não em toda linha);
#   - blocks (from, to): bloqueios criados no período por status, casos
#     (SmallCount 1–4), média de horas da notificação mais antiga do bloqueio
#     (created_at) até a confirmação (cada bloqueio com no mínimo 0 h) e ciclos. Sem linha de total: o total
#     menos as outras linhas revelaria a contagem suprimida.
module VectorControl
  module Reports
    FILTERS = {
      "situations" => %w[cycle_id neighborhood_ids],
      "strategic_points" => %w[cycle_id],
      "production" => %w[from to professional_ids],
      "consumption" => %w[from to],
      "ovitraps" => %w[epi_weeks neighborhood_ids],
      "liraa" => %w[survey_id],
      "blocks" => %w[from to]
    }.freeze
    # O vector_lab lê só estes (ovitrampas e amostras, §10).
    LAB_REPORTS = %w[ovitraps liraa].freeze
    MAX_DAYS = 366
    MAX_WEEKS = 53
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    CLASS_LABELS = { "R" => "R (residencial)", "C" => "C (comércio)", "TB" => "TB (terreno baldio)",
                     "PE" => "PE (ponto estratégico)", "O" => "O (outros)" }.freeze
    STATUS_LABELS = { "proposed" => "Proposto", "active" => "Ativo", "closed" => "Encerrado", "dismissed" => "Descartado" }.freeze
    CAUSE_LABELS = { "no_location" => "sem local", "insufficient_balance" => "saldo insuficiente", "no_lot" => "sem lote" }.freeze
    SITUATION_LABELS = { "worked" => "Trabalhados", "closed" => "Fechados", "refused" => "Recusados", "vacant" => "Desocupados" }.freeze

    # Filtro recusado; `path` é a chave.
    class Invalid < StandardError
      attr_reader :path

      def initialize(path)
        @path = path
        super("invalid filter")
      end
    end

    module_function

    # -> Result.ok(report:, survey: (só no liraa)) | Result.fail(:invalid_request, details: { path: })
    def build(name, filters:)
      raise ArgumentError, "report #{name}" unless Catalog::REPORTS.include?(name)

      filters = filters.to_h.stringify_keys
      if name == "liraa"
        survey = survey!(filters)
        return Result.ok(report: liraa_report(survey), survey: survey)
      end

      Result.ok(report: public_send(name, filters))
    rescue Invalid => e
      Result.fail(:invalid_request, details: { path: e.path })
    end

    def situations(filters)
      cycle = cycle!(filters)
      neighborhoods = neighborhoods!(filters)
      ids = neighborhoods.map(&:id)
      by_class = CycleStats.by_property_class(cycle: cycle, neighborhood_ids: ids)
      by_neighborhood = CycleStats.for(cycle: cycle, neighborhood_ids: ids)
      names = neighborhoods.to_h { |row| [ row.id, row.name ] }
      rows = by_class.map { |stats| situation_row("Classe de imóvel", CLASS_LABELS.fetch(stats[:property_class]), stats) } +
             by_neighborhood.map { |stats| situation_row("Bairro", names.fetch(stats[:neighborhood_id]), stats) }
      registered = by_neighborhood.sum { |stats| stats[:registered_households] }
      without = HouseholdVersion.joins(:household).where("household_versions.version = households.version")
                                .where(neighborhood_id: nil, households: { status: "active" }).count
      notes = [ "Cobertura do cadastro: contam só os #{registered} domicílios ativos do cadastro territorial nos bairros do " \
                "relatório; imóvel fora do cadastro não aparece." ]
      notes << "#{without} domicílio(s) ativo(s) sem bairro no cadastro ficam fora do relatório." if without.positive?
      report("situations",
             [ column("group", "Recorte", "text"), column("label", "Classe ou bairro", "text"),
               column("registered_households", "Cadastrados", "count"), column("to_visit", "A visitar", "count"),
               column("visited", "Visitados", "count"), column("worked", "Trabalhados", "count"),
               column("closed", "Fechados", "count"), column("refused", "Recusados", "count"),
               column("vacant", "Desocupados", "count"), column("recovered", "Recuperados", "count"),
               column("pending_percent", "Pendência %", "percent"), column("coverage_percent", "Cobertura %", "percent") ],
             rows, notes: notes)
    end

    def strategic_points(filters)
      cycle = cycle!(filters)
      period = cycle.starts_on.beginning_of_day...(cycle.ends_on + 1).beginning_of_day
      total = HouseholdVersion.joins(household: :micro_area).where("household_versions.version = households.version")
                              .where(property_type: Catalog::PE_PROPERTY, households: { status: "active" }, micro_areas: { active: true })
                              .count
      last = VectorInspection.valid_inspections
                             .joins("JOIN households pe_households ON pe_households.id = vector_inspections.household_id")
                             .joins("JOIN household_versions pe_versions ON pe_versions.household_id = pe_households.id " \
                                    "AND pe_versions.version = pe_households.version")
                             .joins("JOIN micro_areas pe_areas ON pe_areas.id = pe_households.micro_area_id")
                             .where(home_visits: { occurred_at: period })
                             .where("pe_versions.property_type = ? AND pe_households.status = 'active' AND pe_areas.active",
                                    Catalog::PE_PROPERTY)
                             .select("DISTINCT ON (vector_inspections.household_id) #{visit_day_sql} AS visit_day",
                                     "vector_inspections.situation AS situation")
                             .reorder(Arel.sql("vector_inspections.household_id, home_visits.occurred_at DESC, " \
                                               "vector_inspections.created_at DESC, vector_inspections.id DESC"))
      fortnight = Arel.sql("CASE WHEN extract(day FROM last_pe.visit_day) <= 15 THEN date_trunc('month', last_pe.visit_day)::date " \
                           "ELSE (date_trunc('month', last_pe.visit_day) + interval '15 days')::date END")
      counts = VectorInspection.unscoped.from(last, :last_pe).group(fortnight, "last_pe.situation")
                               .pluck(fortnight, "last_pe.situation", Arel.sql("count(*)"))
                               .each_with_object(Hash.new { |hash, key| hash[key] = Hash.new(0) }) do |(start, situation, count), map|
                                 map[start][situation] += count
                               end
      rows = fortnights(cycle).map do |start|
        stats = counts.fetch(start) { Hash.new(0) }
        { "period" => fortnight_label(start), "strategic_points" => stats.values.sum }
          .merge(Catalog::SITUATIONS.to_h { |situation| [ situation, stats[situation] ] })
      end
      visited = counts.values.sum { |stats| stats.values.sum }
      rows << { "period" => "Sem visita no ciclo", "strategic_points" => total - visited }
                .merge(Catalog::SITUATIONS.to_h { |situation| [ situation, nil ] })
      rows << { "period" => "Total", "strategic_points" => total }
                .merge(Catalog::SITUATIONS.to_h { |situation| [ situation, counts.values.sum { |stats| stats[situation] } ] })
      report("strategic_points",
             [ column("period", "Última visita (quinzena)", "text"), column("strategic_points", "Pontos estratégicos", "count"),
               *Catalog::SITUATIONS.map { |situation| column(situation, SITUATION_LABELS.fetch(situation), "count") } ],
             rows)
    end

    def production(filters)
      range = period!(filters)
      professionals = uuid_list!(filters, "professional_ids")
      base = VectorInspection.valid_inspections
                             .joins("JOIN home_visit_days production_days ON production_days.id = home_visits.home_visit_day_id")
                             .where(home_visits: { occurred_at: range })
      base = base.where("production_days.professional_id IN (?)", professionals) if professionals
      day = Arel.sql(visit_day_sql)
      key = [ Arel.sql("production_days.professional_id"), day ]
      inspections = base.group(*key).pluck(*key, Arel.sql("count(*)"),
                                           Arel.sql("count(*) FILTER (WHERE vector_inspections.situation = 'worked')"))
      deposits = base.joins(:deposits).group(*key)
                     .pluck(*key, Arel.sql("COALESCE(SUM(vector_inspection_deposits.eliminated), 0)"),
                            Arel.sql("COALESCE(SUM(vector_inspection_deposits.treated), 0)"))
                     .to_h { |professional_id, on, *sums| [ [ professional_id, on ], sums.map(&:to_i) ] }
      samples = base.joins(:samples).group(*key).count
      charges = base.joins(:measures).where.not(vector_inspection_measures: { vector_product_id: nil })
                    .group(*key, Arel.sql("vector_inspection_measures.vector_product_id"))
                    .sum("vector_inspection_measures.charges")
      products = VectorProduct.where(id: charges.keys.map(&:last).uniq).order(Arel.sql("lower(code)"), :id).to_a
      names = Professional.where(id: inspections.map(&:first).uniq).pluck(:id, :professional_name).to_h
      rows = inspections.sort_by { |professional_id, on, *| [ sort_key(names[professional_id]), professional_id, on ] }
                        .map do |professional_id, on, count, worked|
        eliminated, treated = deposits.fetch([ professional_id, on ], [ 0, 0 ])
        row = { "professional" => names[professional_id], "day" => on.strftime("%d/%m/%Y"), "households" => count,
                "worked" => worked, "eliminated" => eliminated, "treated" => treated,
                "samples" => samples.fetch([ professional_id, on ], 0) }
        products.each { |product| row["charges_#{product.id}"] = two(charges.fetch([ professional_id, on, product.id ], 0)) }
        row
      end
      report("production",
             [ column("professional", "Agente", "text"), column("day", "Dia", "text"), column("households", "Imóveis", "count"),
               column("worked", "Trabalhados", "count"), column("eliminated", "Depósitos eliminados", "count"),
               column("treated", "Depósitos tratados", "count"), column("samples", "Amostras", "count"),
               *products.map { |product| column("charges_#{product.id}", "Cargas — #{product.code}", "decimal") } ],
             rows)
    end

    def consumption(filters)
      range = period!(filters)
      measures = VectorInspectionMeasure.joins(vector_inspection: :home_visit).merge(HomeVisit.valid)
                                        .where(home_visits: { occurred_at: range }).where.not(vector_product_id: nil)
                                        .group(:vector_product_id)
                                        .pluck(:vector_product_id, Arel.sql("SUM(vector_inspection_measures.charges)"),
                                               Arel.sql("SUM(vector_inspection_measures.quantity)"))
                                        .to_h { |id, *sums| [ id, sums ] }
      # A baixa líquida: aplicação (negativa) mais estorno (positivo), também
      # das visitas retiradas depois (o estorno zera).
      deducted = StockMovement.joins(vector_inspection_measure: { vector_inspection: :home_visit })
                              .where(home_visits: { occurred_at: range })
                              .group("stock_movements.vector_product_id").sum("stock_movements.quantity")
      shortfalls = VectorStockShortfall.joins(vector_inspection_measure: { vector_inspection: :home_visit }).merge(HomeVisit.valid)
                                       .where(home_visits: { occurred_at: range })
                                       .group("vector_stock_shortfalls.vector_product_id", "vector_stock_shortfalls.cause").count
      ids = (measures.keys + deducted.keys + shortfalls.keys.map(&:first)).uniq
      rows = VectorProduct.where(id: ids).order(Arel.sql("lower(code)"), :id).map do |product|
        charges, quantity = measures.fetch(product.id, [ 0, 0 ])
        { "product" => "#{product.code} — #{product.name}", "unit" => product.unit, "charges" => two(charges),
          "quantity" => two(quantity), "deducted" => two((-deducted.fetch(product.id, 0)).nonzero? || 0) }
          .merge(VectorStockShortfall::CAUSES.to_h { |cause| [ "shortfalls_#{cause}", shortfalls.fetch([ product.id, cause ], 0) ] })
      end
      report("consumption",
             [ column("product", "Produto", "text"), column("unit", "Unidade", "text"), column("charges", "Cargas", "decimal"),
               column("quantity", "Quantidade", "decimal"), column("deducted", "Baixa no estoque", "decimal"),
               *VectorStockShortfall::CAUSES.map { |cause| column("shortfalls_#{cause}", "Faltas — #{CAUSE_LABELS.fetch(cause)}", "count") } ],
             rows)
    end

    def ovitraps(filters)
      weeks = epi_weeks!(filters)
      neighborhoods = neighborhoods!(filters)
      names = neighborhoods.to_h { |row| [ row.id, row.name ] }
      rows = OvitrapIndex.for(neighborhood_ids: neighborhoods.map(&:id), epi_weeks: weeks).map do |row|
        { "neighborhood" => names.fetch(row[:neighborhood_id]), "epi_week" => row[:epi_week], "examined" => row[:examined],
          "positive" => row[:positive], "eggs" => row[:eggs], "ipo" => one(row[:ipo]), "ido" => one(row[:ido]),
          "idv" => one(row[:idv]), "lost" => row[:lost], "damaged" => row[:damaged] }
      end
      report("ovitraps",
             [ column("neighborhood", "Bairro", "text"), column("epi_week", "Semana epidemiológica", "text"),
               column("examined", "Examinadas", "count"), column("positive", "Positivas", "count"), column("eggs", "Ovos", "count"),
               column("ipo", "IPO %", "percent"), column("ido", "IDO", "decimal"), column("idv", "IDV", "decimal"),
               column("lost", "Perdidas", "count"), column("damaged", "Avariadas", "count") ],
             rows)
    end

    # O relatório do LIRAa do levantamento (também do PDF).
    def liraa_report(survey)
      index = Liraa::Index.for(survey)
      town = index[:municipality]
      # O provisório do levantamento em toda linha: a linha exportada (CSV) não perde o aviso.
      flag = town[:provisional] ? "sim" : "não"
      rows = (index[:strata].map { |stratum| liraa_row(stratum[:name], stratum) } + [ liraa_row("Município", town) ])
             .map { |row| row.merge("provisional" => flag) }
      notes = []
      notes << "Provisório: há amostra sem resultado de laboratório." if town[:provisional]
      notes << "#{town[:missing]} imóvel(is) substituído(s) sem candidato." if town[:missing].positive?
      report("liraa",
             [ column("stratum", "Estrato", "text"), column("planned", "Amostra planejada", "count"),
               column("inspected", "Inspecionados", "count"), column("substitutions", "Substituições", "count"),
               column("missing", "Substituídos sem candidato", "count"), column("positive_households", "Imóveis positivos", "count"),
               column("positive_containers", "Recipientes positivos", "count"), column("iip", "IIP %", "percent"),
               column("iip_class", "Classe do IIP", "text"), column("ib", "IB %", "percent"),
               *Catalog::DEPOSIT_GROUPS.map { |group| column("itr_#{group}", "ITR #{group} %", "percent") },
               column("provisional", "Provisório", "text") ],
             rows, notes: notes, provisional: town[:provisional])
    end

    def blocks(filters)
      range = period!(filters)
      cases = TransmissionBlockCase.joins(:disease_notification).group(:transmission_block_id)
                                   .select("transmission_block_cases.transmission_block_id AS block_id", "count(*) AS cases",
                                           "min(disease_notifications.created_at) AS first_notified_at")
      cycles = TransmissionBlockCycle.group(:transmission_block_id)
                                     .select("transmission_block_cycles.transmission_block_id AS block_id", "count(*) AS cycles")
      # Cada bloqueio com no mínimo 0 h: depois de mover casos, a notificação
      # mais antiga que sobrou pode ser posterior à confirmação.
      hours = "GREATEST(extract(epoch FROM (transmission_blocks.confirmed_at - " \
              "(block_cases.first_notified_at AT TIME ZONE 'UTC'))) / 3600, 0)"
      counts = TransmissionBlock.where(created_at: range)
                                .joins("LEFT JOIN (#{cases.to_sql}) block_cases ON block_cases.block_id = transmission_blocks.id")
                                .joins("LEFT JOIN (#{cycles.to_sql}) block_cycles ON block_cycles.block_id = transmission_blocks.id")
                                .group(:status)
                                .pluck(:status, Arel.sql("count(*)"), Arel.sql("COALESCE(SUM(block_cases.cases), 0)"),
                                       Arel.sql("AVG(#{hours}) FILTER (WHERE transmission_blocks.confirmed_at IS NOT NULL)"),
                                       Arel.sql("COALESCE(SUM(block_cycles.cycles), 0)"))
                                .to_h { |status, *numbers| [ status, numbers ] }
      rows = Catalog::BLOCK_STATUSES.map do |status|
        count, case_count, average, cycle_count = counts.fetch(status, [ 0, 0, nil, 0 ])
        { "status" => STATUS_LABELS.fetch(status), "blocks" => count.to_i, "cases" => Admin::SmallCount.wrap(case_count.to_i),
          "hours_to_confirmation" => average && BigDecimal(average.to_s).round(1, BigDecimal::ROUND_HALF_UP).to_s("F"),
          "cycles" => cycle_count.to_i }
      end
      report("blocks",
             [ column("status", "Status", "text"), column("blocks", "Bloqueios", "count"), column("cases", "Casos", "count"),
               column("hours_to_confirmation", "Horas até a confirmação (média)", "decimal"), column("cycles", "Ciclos", "count") ],
             rows,
             notes: [ "Casos de 1 a 4 saem suprimidos.",
                      "Horas: da notificação mais antiga do bloqueio até a confirmação; média dos bloqueios confirmados." ])
    end

    # --- linhas e formatos ---

    def situation_row(group, label, stats)
      { "group" => group, "label" => label, "registered_households" => stats[:registered_households], "to_visit" => stats[:to_visit],
        "visited" => stats[:visited], "worked" => stats[:worked], "closed" => stats[:closed], "refused" => stats[:refused],
        "vacant" => stats[:vacant], "recovered" => stats[:recovered], "pending_percent" => one(stats[:pending_percent]),
        "coverage_percent" => Liraa::Index.text(Liraa::Index.percent(stats[:visited], stats[:to_visit])) }
    end

    def liraa_row(name, summary)
      { "stratum" => name, "planned" => summary[:planned], "inspected" => summary[:inspected],
        "substitutions" => summary[:substitutions], "missing" => summary[:missing],
        "positive_households" => summary[:positive_households], "positive_containers" => summary[:positive_containers],
        "iip" => summary[:iip], "iip_class" => summary[:iip_class], "ib" => summary[:ib] }
        .merge(Catalog::DEPOSIT_GROUPS.to_h { |group| [ "itr_#{group}", summary[:itr].fetch(group) ] })
    end

    def report(name, columns, rows, notes: nil, provisional: nil)
      shaped = { name: name }
      shaped[:provisional] = provisional unless provisional.nil?
      shaped.merge!(columns: columns, rows: rows)
      shaped[:notes] = notes if notes.present?
      shaped
    end

    def column(key, label, kind) = { key: key, label: label, kind: kind }

    def one(value) = value.nil? ? nil : format("%.1f", value)
    def two(value) = format("%.2f", BigDecimal(value.to_s))

    def sort_key(name) = I18n.transliterate(name.to_s).downcase

    # Dia da visita no fuso da cidade (occurred_at é timestamp sem fuso, em UTC).
    def visit_day_sql
      zone = HomeVisit.connection.quote(Time.zone.tzinfo.identifier)
      "((home_visits.occurred_at AT TIME ZONE 'UTC') AT TIME ZONE #{zone})::date"
    end

    # Início de cada quinzena (dia 1 ou 16) que o ciclo toca, em ordem.
    def fortnights(cycle)
      start = fortnight_of(cycle.starts_on)
      last = fortnight_of(cycle.ends_on)
      starts = []
      while start <= last
        starts << start
        start = start.day == 1 ? start + 15 : start.next_month.beginning_of_month
      end
      starts
    end

    def fortnight_of(date) = date.day <= 15 ? date.beginning_of_month : date.beginning_of_month + 15

    def fortnight_label(start)
      finish = start.day == 1 ? start + 14 : start.end_of_month
      "#{start.strftime('%d')}–#{finish.strftime('%d/%m/%Y')}"
    end

    # --- filtros ---

    def cycle!(filters) = record!(VectorCycle, filters, "cycle_id")
    def survey!(filters) = record!(LiraaSurvey, filters, "survey_id")

    def record!(model, filters, key)
      raw = filters[key]
      raise Invalid, key unless raw.is_a?(String) && raw.match?(UUID)

      model.find_by(id: raw) || raise(Invalid, key)
    end

    # Os bairros pedidos, na ordem da query; sem a chave, os ativos por nome.
    def neighborhoods!(filters)
      return Neighborhood.active_neighborhoods.order(:name, :id).to_a unless filters.key?("neighborhood_ids")

      ids = uuid_list!(filters, "neighborhood_ids")
      found = Neighborhood.where(id: ids).index_by(&:id)
      missing = ids.index { |id| !found.key?(id) }
      raise Invalid, "neighborhood_ids[#{missing}]" if missing

      ids.uniq.map { |id| found.fetch(id) }
    end

    # Lista de UUIDs da query (`key[]=`): nil sem a chave; vazia ou com item
    # inválido → Invalid.
    def uuid_list!(filters, key)
      return nil unless filters.key?(key)

      raw = filters[key]
      raise Invalid, key unless raw.is_a?(Array) && raw.any?

      bad = raw.index { |id| !(id.is_a?(String) && id.match?(UUID)) }
      raise Invalid, "#{key}[#{bad}]" if bad

      raw
    end

    def epi_weeks!(filters)
      raw = filters["epi_weeks"]
      raise Invalid, "epi_weeks" unless raw.is_a?(Array) && raw.any? && raw.size <= MAX_WEEKS

      weeks = raw.map { |value| Surveillance::EpiWeek.parse(value) }
      bad = weeks.index(nil)
      raise Invalid, "epi_weeks[#{bad}]" if bad

      weeks.uniq
    end

    # from..to (dias da cidade, os dois inclusive, até MAX_DAYS) como faixa de horas.
    def period!(filters)
      from = date!(filters, "from")
      to = date!(filters, "to")
      raise Invalid, "to" if to < from || (to - from).to_i >= MAX_DAYS

      from.beginning_of_day...(to + 1).beginning_of_day
    end

    def date!(filters, key)
      raw = filters[key]
      raise Invalid, key unless raw.is_a?(String) && raw.match?(DATE)

      Date.strptime(raw, "%Y-%m-%d")
    rescue Date::Error
      raise Invalid, key
    end
  end
end
