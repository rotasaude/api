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
#     null na mecânica) e product; amostras com id, label e result.
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
