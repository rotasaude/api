# Grava o boletim do agente de endemias na visita (módulo 35a, ADR 0054;
# contrato §3, §9, Q7(1); plano, Review Focus 1). Só o HomeVisits::Record
# chama, na transação da visita:
#   - facts! (logo depois do domicílio, antes das regras): trava o perfil do
#     imóvel FOR UPDATE (criado se faltar; SaveProfile.lock_profiles!), lê o
#     quarteirão citado FOR SHARE, trava o item do LIRAa FOR UPDATE, lê o
#     bloqueio FOR SHARE e os produtos das medidas FOR SHARE (Task 7: a troca
#     de unidade ou carga do VectorControl::SaveProduct, FOR UPDATE, espera a
#     visita, e a quantidade da medida usa a carga relida sob a trava) — a ordem
#     pacientes → domicílio → perfil → item do LIRAa → bloqueio → produtos →
#     folha → visita → lotes → local — e devolve os InspectionRules::Facts;
#   - call (depois do insert! da visita, com as regras já aceitas): a
#     inspeção (quarteirão do perfil congelado; `recovered`), os depósitos, as
#     medidas (quantidade pelo produto da hora, A-2), as amostras (etiqueta do
#     §9; colisão no idx_vector_samples_label → recusa sample_label_taken com o
#     índice da amostra, Q7(1)), o perfil (quarteirão da regra 10, risco, o
#     último trabalho; version + 1 e household_vector_profile.changed) e o item
#     do LIRAa (Liraa::Items.inspected!). Depois das medidas e antes das
#     amostras, a baixa de estoque (VectorControl::ApplyStock: lotes → local,
#     savepoint por medida, falta em vez de recusa).
# Nenhum evento próprio: a inspeção vai no home_visit.recorded (§17); a falta
# publica vector_stock.shortfall_recorded.
module VectorControl
  module RecordInspection
    UUID = InspectionRules::UUID
    LABEL_INDEX = "idx_vector_samples_label".freeze

    module_function

    # -> InspectionRules::Facts. `input` é o `vector_inspection` do corpo (pode
    # vir malformado: as regras recusam a forma; aqui só se lê o que é id).
    # Gate fora de uso ou outro CBO: nenhum fato lido, nenhuma trava nem perfil
    # criado (a regra 1 recusa com os fatos vazios).
    def facts!(input, household:, cbo:, usable:, outcome:, occurred_at:, by:)
      unless usable && cbo == TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO
        return InspectionRules::Facts.new(usable: usable, cbo: cbo, outcome: outcome, occurred_at: occurred_at, property_type: nil,
                                          profile_block_id: nil, city_block: nil, liraa_item: nil, transmission_block: nil, products: {})
      end

      input = {} unless input.is_a?(Hash)
      profile = household && SaveProfile.lock_profiles!([ household.id ], by: by).first.fetch(household.id)
      InspectionRules::Facts.new(
        usable: usable, cbo: cbo, outcome: outcome, occurred_at: occurred_at,
        property_type: household&.latest_version&.property_type, profile_block_id: profile&.city_block_id,
        city_block: city_block(input["city_block_id"]),
        liraa_item: (liraa_item(input["liraa_draw_item_id"]) if input["activity"] == "liraa"),
        transmission_block: (transmission_block(input["transmission_block_id"]) if input["activity"] == "transmission_block"),
        products: products(input["measures"])
      )
    end

    # -> VectorInspection (refusal sample_label_taken levanta
    # HomeVisits::Record::Refused, que desfaz a visita inteira).
    def call(visit:, input:, facts:, by:, today:)
      day = visit.occurred_at.in_time_zone.to_date
      block_id = facts.profile_block_id || input["city_block_id"]&.downcase
      inspection = VectorInspection.create!(
        home_visit: visit, household_id: visit.household_id, city_block_id: block_id, activity: input["activity"],
        work_type: input["work_type"], situation: input["situation"], educational_action: input["educational_action"],
        entered_at: input["entered_at"], left_at: input["left_at"],
        liraa_draw_item_id: (input["liraa_draw_item_id"] if input["activity"] == "liraa"),
        transmission_block_id: (input["transmission_block_id"] if input["activity"] == "transmission_block"),
        recovered: recovered?(input, visit)
      )
      deposits!(inspection, input)
      measures!(inspection, input, facts)
      ApplyStock.call(inspection: inspection, by: by, today: today)
      samples!(inspection, input, visit)
      profile!(visit, input, day, by)
      item = inspection.liraa_draw_item_id && LiraaDrawItem.find(inspection.liraa_draw_item_id) # já travado no facts!
      Liraa::Items.inspected!(item, situation: inspection.situation) if item
      inspection
    end

    # Último trabalho do domicílio pelas inspeções válidas (visita não
    # retirada), pela hora da visita: a mais recente e o dia da mais recente
    # trabalhada. Também serve à retirada (WithdrawInspection).
    def last_attributes(household_id)
      scope = VectorInspection.valid_inspections.where(household_id: household_id)
      last = scope.order("home_visits.occurred_at DESC, vector_inspections.created_at DESC, vector_inspections.id DESC").first
      worked = scope.where(situation: "worked").maximum("home_visits.occurred_at")
      { last_inspection_id: last&.id, last_situation: last&.situation, last_worked_on: worked&.in_time_zone&.to_date }
    end

    # --- fatos ---------------------------------------------------------------

    def city_block(id)
      block = uuid?(id) && CityBlock.lock("FOR SHARE").find_by(id: id)
      block && { id: block.id, neighborhood_id: block.neighborhood_id, active: block.active }
    end

    # Item travado FOR UPDATE; o levantamento lido sem trava (o fechamento o
    # trava antes dos itens; o trigger recusa mudar item de levantamento fechado).
    def liraa_item(id)
      item = uuid?(id) && LiraaDrawItem.lock.find_by(id: id)
      item && { id: item.id, household_id: item.household_id, status: item.status, survey_status: Liraa::Items.survey_status(item) }
    end

    def transmission_block(id)
      block = uuid?(id) && TransmissionBlock.lock("FOR SHARE").find_by(id: id)
      block && { id: block.id, status: block.status,
                 area_block_ids: TransmissionBlockArea.where(transmission_block_id: block.id).pluck(:city_block_id) }
    end

    def products(measures)
      ids = Array(measures).filter_map { |measure| measure["vector_product_id"] if measure.is_a?(Hash) && uuid?(measure["vector_product_id"]) }
      return {} if ids.empty?

      VectorProduct.where(id: ids.map(&:downcase).uniq).order(:id).lock("FOR SHARE").to_h do |product|
        [ product.id, { active: product.active, uses: product.uses, unit: product.unit, charge_size: product.charge_size } ]
      end
    end

    # --- escritas ------------------------------------------------------------

    # Pendência trabalhada depois de fechada ou recusada: a inspeção válida
    # anterior do domicílio (pela hora da visita) em PENDING_SITUATIONS.
    def recovered?(input, visit)
      return false unless input["work_type"] == "pending" && input["situation"] == "worked"

      previous = VectorInspection.valid_inspections.where(household_id: visit.household_id)
                                 .where.not(home_visit_id: visit.id).where(home_visits: { occurred_at: ..visit.occurred_at })
                                 .order("home_visits.occurred_at DESC, vector_inspections.created_at DESC, vector_inspections.id DESC")
                                 .pick(:situation)
      Catalog::PENDING_SITUATIONS.include?(previous)
    end

    def deposits!(inspection, input)
      Array(input["deposits"]).each do |deposit|
        VectorInspectionDeposit.create!(deposit.slice(*InspectionRules::DEPOSIT_KEYS).merge(vector_inspection_id: inspection.id))
      end
    end

    def measures!(inspection, input, facts)
      Array(input["measures"]).map do |measure|
        product_id = measure["vector_product_id"]&.downcase
        charges = product_id && BigDecimal(measure["charges"].to_s)
        VectorInspectionMeasure.create!(
          vector_inspection_id: inspection.id, method: measure["method"], vector_product_id: product_id, charges: charges,
          quantity: product_id && InspectionRules.quantity(charges, facts.products.fetch(product_id).fetch(:charge_size))
        )
      end
    end

    # Uma a uma, cada uma no seu savepoint: a colisão aponta a amostra.
    def samples!(inspection, input, visit)
      Array(input["samples"]).each_with_index do |sample, index|
        VectorSample.transaction(requires_new: true) do
          VectorSample.create!(vector_inspection_id: inspection.id, number: sample["number"], deposit_group: sample["deposit_group"],
                               larvae_collected: sample["larvae_collected"], label: InspectionRules.label(visit.client_uuid, sample["number"]))
        end
      rescue ActiveRecord::RecordNotUnique => e
        raise unless e.message.include?(LABEL_INDEX)

        raise HomeVisits::Record::Refused, Result.fail(:sample_label_taken, details: { path: "vector_inspection.samples[#{index}]" })
      end
    end

    # O perfil já está travado (facts!). Quarteirão só se nulo (regra 10);
    # risco com o dia da visita; o último trabalho pelas inspeções válidas.
    def profile!(visit, input, day, by)
      profile = HouseholdVectorProfile.find_by!(household_id: visit.household_id)
      attrs = last_attributes(visit.household_id)
      attrs[:city_block_id] = input["city_block_id"].downcase if input.key?("city_block_id") && profile.city_block_id.nil?
      attrs.merge!(risk_class: input["risk_class"], risk_assessed_on: day) if input.key?("risk_class")
      SaveProfile.write!(profile, attrs, by, created: false)
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    private_class_method :city_block, :liraa_item, :transmission_block, :products, :recovered?, :deposits!, :measures!, :samples!,
                         :profile!, :uuid?
  end
end
