# Formas JSON da vigilância ambiental (módulo 35a, ADR 0054; contrato §2;
# Q8: os tipos da Task 1 do plano do dashboard). Nunca nome, CPF, CNS,
# telefone ou morador: o imóvel sai só com o endereço curto do 24a
# (HomeVisits::Json.address_short), e quem lista grava a trilha.
#   - block → CityBlock (`blocks` em lote: vizinhos vigentes e
#     households_count = domicílios ativos com o quarteirão no perfil, uma
#     consulta agrupada por página);
#   - profile → HouseholdVector (o mesmo `<household>.vector` do app: um
#     serializador só); nil sem perfil;
#   - household_row → VectorHousehold (`household_rows` em lote);
#   - inspection → VectorInspection (o boletim no <home_visit> do 24b; Q8):
#     os campos do §3 menos city_block_id (e risk_class, que fica no perfil),
#     mais id, recovered e city_block; medidas com quantity (texto, 2 casas;
#     null na mecânica) e product; amostras com id, label e result;
#   - product → VectorProduct (`charge_size` em texto, 2 casas, Q15; `in_use` =
#     há lote ou medida do produto); `products` em lote;
#   - settings → VectorSettings (o local da baixa e as opções: os locais
#     vector_control ativos);
#   - shortfalls → VectorShortfall (o produto, o local, o dia da visita e quem
#     conciliou; `reconciled_by: null` na conciliação do sistema). A nota
#     nunca sai;
#   - cadences → VectorCadence[] (cidade primeiro); cycle → VectorCycle;
#     cycle_summary → CycleSummary (VectorControl::CycleStats por bairro);
#   - ovitraps → Ovitrap[]; ovitrap_readings → OvitrapReading[]; tasks →
#     VectorTask[] (Task 9; semana em "YYYY-WW", A-9; notas nunca saem).
#   - liraa_surveys → LiraaSurvey[] (Task 10: estratos na ordem do
#     levantamento, block_ids na ordem gravada; N, n, intervalo e início nulos
#     antes do sorteio); liraa_items → LiraaItem[] (o domicílio só com o
#     endereço curto; quem mostra grava a trilha).
module VectorControl
  module Json
    module_function

    def blocks(blocks)
      ids = blocks.map(&:id)
      neighbors = neighbor_ids(ids)
      counts = households_counts(ids)
      blocks.map { |block| block(block, neighbor_ids: neighbors.fetch(block.id, []), households_count: counts.fetch(block.id, 0)) }
    end

    # Quarteirão com o bairro carregado por quem chama.
    def block(block, neighbor_ids: nil, households_count: nil)
      return blocks([ block ]).first if neighbor_ids.nil? || households_count.nil?

      { id: block.id, neighborhood: { id: block.neighborhood.id, name: block.neighborhood.name }, number: block.number,
        active: block.active, neighbor_ids: neighbor_ids, households_count: households_count, version: block.version }
    end

    def profile(profile)
      return nil unless profile

      { city_block_id: profile.city_block_id, risk_class: profile.risk_class, risk_assessed_on: profile.risk_assessed_on&.iso8601,
        last_worked_on: profile.last_worked_on&.iso8601, last_situation: profile.last_situation }
    end

    # Domicílios com micro_area carregada; a versão atual, o endereço curto
    # (HomeVisits::Json.addresses) e o perfil (com o quarteirão) em lote.
    def household_rows(households)
      ids = households.map(&:id)
      versions = HouseholdVersion.joins(:household).where(household_id: ids).where("household_versions.version = households.version")
                                 .index_by(&:household_id)
      addresses = HomeVisits::Json.addresses(ids)
      profiles = HouseholdVectorProfile.includes(:city_block).where(household_id: ids).index_by(&:household_id)
      households.map do |household|
        household_row(household, version: versions.fetch(household.id), address_short: addresses.fetch(household.id),
                                 profile: profiles[household.id])
      end
    end

    def household_row(household, version:, address_short:, profile:)
      block = profile&.city_block
      vector = profile(profile) || {}
      { id: household.id, address_short: address_short, property_type: version.property_type,
        neighborhood_id: version.neighborhood_id, micro_area: { id: household.micro_area.id, code: household.micro_area.code },
        block: block && { id: block.id, number: block.number, neighborhood_id: block.neighborhood_id },
        risk_class: vector[:risk_class], risk_assessed_on: vector[:risk_assessed_on], last_worked_on: vector[:last_worked_on],
        last_situation: vector[:last_situation] }
    end

    # { home_visit_id => <inspection> } das visitas, em consultas constantes
    # (inspeções, depósitos, medidas com produto, amostras e quarteirões).
    def inspections(home_visit_ids)
      return {} if home_visit_ids.empty?

      VectorInspection.where(home_visit_id: home_visit_ids)
                      .includes(:city_block, :deposits, :samples, measures: :vector_product)
                      .to_h { |inspection| [ inspection.home_visit_id, inspection(inspection) ] }
    end

    def inspection(inspection)
      block = inspection.city_block
      {
        id: inspection.id, activity: inspection.activity, work_type: inspection.work_type, situation: inspection.situation,
        educational_action: inspection.educational_action, entered_at: inspection.entered_at&.iso8601,
        left_at: inspection.left_at&.iso8601, liraa_draw_item_id: inspection.liraa_draw_item_id,
        transmission_block_id: inspection.transmission_block_id
      }.compact.merge(
        recovered: inspection.recovered, city_block: block && { id: block.id, number: block.number },
        deposits: inspection.deposits.sort_by { |deposit| Catalog::DEPOSIT_GROUPS.index(deposit.group) }.map do |deposit|
          { group: deposit.group, existing: deposit.existing, with_water: deposit.with_water, with_larvae: deposit.with_larvae,
            eliminated: deposit.eliminated, treated: deposit.treated }
        end,
        measures: inspection.measures.sort_by { |measure| [ Catalog::METHODS.index(measure.method), measure.vector_product&.code.to_s ] }
                            .map { |measure| measure(measure) },
        samples: inspection.samples.sort_by(&:number).map { |sample| sample(sample) }
      )
    end

    def measure(measure)
      product = measure.vector_product
      json = { method: measure.method }
      json.merge!(vector_product_id: product.id, charges: measure.charges.to_f) if product
      json.merge(quantity: measure.quantity && format("%.2f", measure.quantity),
                 product: product && { id: product.id, code: product.code, name: product.name, unit: product.unit })
    end

    # Resultado só com os números e a data; `corrected` = houve correção (a
    # nota existe só nela). A nota nunca sai, nem decifrada aqui.
    def sample(sample)
      result = sample.result_at && {
        examined_larvae: sample.examined_larvae, aegypti_larvae: sample.aegypti_larvae, albopictus_larvae: sample.albopictus_larvae,
        result_at: sample.result_at.iso8601, corrected: !sample.read_attribute_before_type_cast("result_note").nil?
      }
      { id: sample.id, number: sample.number, deposit_group: sample.deposit_group, larvae_collected: sample.larvae_collected,
        label: sample.label, result: result }
    end

    def products(products)
      ids = products.map(&:id)
      used = StockLot.where(vector_product_id: ids).distinct.pluck(:vector_product_id).to_set +
             VectorInspectionMeasure.where(vector_product_id: ids).distinct.pluck(:vector_product_id)
      products.map { |product| product(product, in_use: used.include?(product.id)) }
    end

    def product(product, in_use: nil)
      return products([ product ]).first if in_use.nil?

      { id: product.id, code: product.code, name: product.name, unit: product.unit, charge_size: format("%.2f", product.charge_size),
        uses: product.uses, active: product.active, in_use: in_use }
    end

    def settings(setting)
      location = setting.stock_location
      { stock_location: location && { id: location.id, name: location.name },
        options: StockLocation.active_locations.where(kind: "vector_control").order(:name, :id).map { |row| { id: row.id, name: row.name } } }
    end

    def shortfalls(rows)
      measures = VectorInspectionMeasure.where(id: rows.map(&:vector_inspection_measure_id)).includes(vector_inspection: :home_visit).index_by(&:id)
      products = VectorProduct.where(id: rows.map(&:vector_product_id)).index_by(&:id)
      locations = StockLocation.where(id: rows.filter_map(&:stock_location_id)).index_by(&:id)
      users = User.where(id: rows.filter_map(&:reconciled_by_user_id)).includes(:professional).index_by(&:id)
      rows.map do |row|
        product = products.fetch(row.vector_product_id)
        location = locations[row.stock_location_id]
        reconciler = users[row.reconciled_by_user_id]
        { id: row.id, created_at: row.created_at.utc.iso8601(6), stock_location: location && { id: location.id, name: location.name },
          product: { id: product.id, code: product.code, name: product.name, unit: product.unit },
          quantity: format("%.2f", row.quantity), cause: row.cause,
          visit_on: measures.fetch(row.vector_inspection_measure_id).vector_inspection.home_visit.occurred_at.in_time_zone.to_date.iso8601,
          reconciled_at: row.reconciled_at&.utc&.iso8601, reconciled_by: reconciler && { name: reconciler.professional&.professional_name } }
      end
    end

    # VectorCadence[]: a cidade primeiro, depois os bairros (pelo nome, sem
    # acento nem caixa, e id); dentro de cada um, os riscos (qualquer primeiro, na ordem
    # de RISK_CLASSES) e o PE. Os nomes numa consulta.
    def cadences(rows)
      names = Neighborhood.where(id: rows.filter_map(&:neighborhood_id).uniq).pluck(:id, :name).to_h
      rows.sort_by do |row|
        [ row.neighborhood_id ? 1 : 0, I18n.transliterate(names[row.neighborhood_id].to_s).downcase, row.neighborhood_id.to_s, row.strategic_point ? 1 : 0,
          row.risk_class ? Catalog::RISK_CLASSES.index(row.risk_class) + 1 : 0 ]
      end.map do |row|
        { neighborhood_id: row.neighborhood_id, risk_class: row.risk_class, strategic_point: row.strategic_point, days: row.days }
      end
    end

    def cycle(cycle)
      { id: cycle.id, year: cycle.year, number: cycle.number, starts_on: cycle.starts_on.iso8601, ends_on: cycle.ends_on.iso8601 }
    end

    # CycleSummary: o ciclo e, por bairro (na ordem dada), os números do
    # CycleStats com o bairro `{ id, name }` no lugar do id.
    def cycle_summary(cycle, neighborhoods)
      stats = CycleStats.for(cycle: cycle, neighborhood_ids: neighborhoods.map(&:id))
      by_id = neighborhoods.index_by(&:id)
      { cycle: cycle(cycle),
        neighborhoods: stats.map do |row|
          neighborhood = by_id.fetch(row[:neighborhood_id])
          { neighborhood: { id: neighborhood.id, name: neighborhood.name } }.merge(row.except(:neighborhood_id))
        end }
    end

    # Ovitrap[] (Task 9): o domicílio só com o endereço curto do 24a (quem
    # mostra grava a trilha), o quarteirão congelado, a leitura aberta e a
    # última coletada (por collected_on), em consultas constantes. epi_week em
    # "YYYY-WW" (A-9). Nunca morador.
    def ovitraps(ovitraps)
      ids = ovitraps.map(&:id)
      open = OvitrapReading.open_readings.where(ovitrap_id: ids).index_by(&:ovitrap_id)
      last = OvitrapReading.where(ovitrap_id: ids).where.not(collected_on: nil)
                           .select("DISTINCT ON (ovitrap_readings.ovitrap_id) ovitrap_readings.*")
                           .order(:ovitrap_id, collected_on: :desc, created_at: :desc).index_by(&:ovitrap_id)
      blocks = CityBlock.where(id: ovitraps.map(&:city_block_id)).index_by(&:id)
      addresses = HomeVisits::Json.addresses(ovitraps.map(&:household_id))
      ovitraps.map do |ovitrap|
        block = blocks.fetch(ovitrap.city_block_id)
        current = open[ovitrap.id]
        previous = last[ovitrap.id]
        { id: ovitrap.id, number: ovitrap.number, household: { id: ovitrap.household_id, address_short: addresses.fetch(ovitrap.household_id) },
          city_block: { id: block.id, number: block.number }, status: ovitrap.status, installed_on: ovitrap.installed_on.iso8601,
          removed_on: ovitrap.removed_on&.iso8601, open_reading: current && { id: current.id, installed_on: current.installed_on.iso8601 },
          last_reading: previous && { id: previous.id, collected_on: previous.collected_on.iso8601, condition: previous.condition,
                                      egg_count: previous.egg_count, epi_week: OvitrapIndex.week_text(previous.epi_week) },
          version: ovitrap.version }
      end
    end

    # OvitrapReading[] (Task 9): a ovitrampa, o quarteirão e o bairro dele, a
    # semana em "YYYY-WW" e `corrected` (há nota só na correção). A nota nunca
    # sai, nem decifrada aqui.
    def ovitrap_readings(readings)
      ovitraps = Ovitrap.where(id: readings.map(&:ovitrap_id).uniq).includes(city_block: :neighborhood).index_by(&:id)
      readings.map do |reading|
        ovitrap = ovitraps.fetch(reading.ovitrap_id)
        block = ovitrap.city_block
        { id: reading.id, ovitrap: { id: ovitrap.id, number: ovitrap.number }, city_block: { id: block.id, number: block.number },
          neighborhood: { id: block.neighborhood.id, name: block.neighborhood.name }, installed_on: reading.installed_on.iso8601,
          collected_on: reading.collected_on&.iso8601, condition: reading.condition, epi_week: OvitrapIndex.week_text(reading.epi_week),
          egg_count: reading.egg_count, counted_at: reading.counted_at&.utc&.iso8601,
          corrected: !reading.read_attribute_before_type_cast("count_note").nil? }
      end
    end

    # VectorTask[] (Task 9): a ovitrampa (número) e os quarteirões sugeridos
    # na intensificação; doença e data no caso de residente fora (nunca o
    # paciente: só disease_code e suspected_on da notificação); o bloqueio no
    # caso sem imóvel. closed_at = a última escrita da tarefa fechada (fecha
    # uma vez). A nota nunca sai.
    def tasks(tasks)
      ovitraps = Ovitrap.where(id: tasks.filter_map(&:ovitrap_id)).pluck(:id, :number).to_h
      numbers = CityBlock.where(id: tasks.flat_map(&:suggested_block_ids).uniq).pluck(:id, :number).to_h
      cases = DiseaseNotification.where(id: tasks.filter_map(&:disease_notification_id))
                                 .pluck(:id, :disease_code, :suspected_on).to_h { |id, *rest| [ id, rest ] }
      tasks.map do |task|
        disease, case_on = cases[task.disease_notification_id]
        { id: task.id, kind: task.kind, state: task.state, created_at: task.created_at.utc.iso8601,
          ovitrap: task.ovitrap_id && { id: task.ovitrap_id, number: ovitraps.fetch(task.ovitrap_id) },
          suggested_blocks: task.suggested_block_ids.map { |id| { id: id, number: numbers.fetch(id) } },
          disease: disease, case_on: case_on&.iso8601, transmission_block_id: task.transmission_block_id,
          closed_at: task.state == "open" ? nil : task.updated_at.utc.iso8601 }
      end
    end

    # LiraaSurvey[]: estratos e quarteirões em duas consultas.
    def liraa_surveys(surveys)
      strata = LiraaStratum.where(liraa_survey_id: surveys.map(&:id)).order(:created_at, :id).to_a
      blocks = LiraaStratumBlock.where(liraa_stratum_id: strata.map(&:id)).order(:created_at, :id)
                                .pluck(:liraa_stratum_id, :city_block_id).group_by(&:first)
      by_survey = strata.group_by(&:liraa_survey_id)
      surveys.map do |survey|
        { id: survey.id, name: survey.name, starts_on: survey.starts_on.iso8601, ends_on: survey.ends_on.iso8601, status: survey.status,
          parameters_version: survey.parameters_version, drawn_at: survey.drawn_at&.utc&.iso8601, closed_at: survey.closed_at&.utc&.iso8601,
          strata: by_survey.fetch(survey.id, []).map do |stratum|
            { id: stratum.id, name: stratum.name, mode: stratum.mode, block_ids: blocks.fetch(stratum.id, []).map(&:last),
              households_count: stratum.households_count, sample_target: stratum.sample_target, block_interval: stratum.block_interval,
              random_start: stratum.random_start }
          end }
      end
    end

    def liraa_survey(survey) = liraa_surveys([ survey ]).sole

    # LiraaItem[]: o quarteirão (número) e o endereço curto do 24a. Nunca morador.
    def liraa_items(items)
      numbers = CityBlock.where(id: items.map(&:city_block_id).uniq).pluck(:id, :number).to_h
      addresses = HomeVisits::Json.addresses(items.map(&:household_id))
      items.map do |item|
        { id: item.id, stratum_id: item.liraa_stratum_id, city_block: { id: item.city_block_id, number: numbers.fetch(item.city_block_id) },
          household: { id: item.household_id, address_short: addresses.fetch(item.household_id) }, position: item.position,
          status: item.status, substitute_of_id: item.substitute_of_id }
      end
    end

    # { block_id => [ids dos vizinhos vigentes] }, ordenados.
    def neighbor_ids(ids)
      return {} if ids.empty?

      pairs = CityBlockNeighbor.current.where(city_block_id: ids).or(CityBlockNeighbor.current.where(neighbor_block_id: ids))
                               .pluck(:city_block_id, :neighbor_block_id)
      wanted = ids.to_set
      pairs.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(a, b), map|
        map[a] << b if wanted.include?(a)
        map[b] << a if wanted.include?(b)
      end.transform_values(&:sort)
    end

    def households_counts(ids)
      return {} if ids.empty?

      HouseholdVectorProfile.joins(:household).where(city_block_id: ids, households: { status: "active" }).group(:city_block_id).count
    end
  end
end
