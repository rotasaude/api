# Sorteio do LIRAa (módulo 35a, ADR 0054; contrato §7; Q16, Q17, Q18; A-4).
# Só a coordenação, com step-up (quem chama confere). Trava o levantamento
# FOR UPDATE; fora de draft → survey_not_draft (409). Por estrato, na ordem do
# levantamento:
#   - a base (`base`): domicílios ativos com o quarteirão no perfil, sem ponto
#     estratégico (tipo 4, Q16(d)), por (registered_at, id); N = o total;
#   - os quarteirões por (nome do bairro, bairro, número natural:
#     CityBlock.natural_number_order, Q18); B = quantos;
#   - quarteirão desativado depois da gravação (relido FOR SHARE) →
#     invalid_request path strata[i] (o código do SaveSurvey), nada gravado;
#   - Liraa::Sample.plan (standard e half com quarteirões sistemáticos, Q17;
#     census, todos); fora da faixa → stratum_out_of_range path strata[i], nada
#     gravado;
#   - início casual r em 1..k (`random`; k = 1 → 1); sorteados r, r+k, … até b;
#   - em cada quarteirão sorteado, household_start = 1 sempre (Q16(b)) e os
#     imóveis de Sample.household_positions (fração e intervalo do modo).
# Grava N, n, k e r no estrato, o início e a base do quarteirão sorteado
# (base_household_ids, na ordem: o substituto sai só dela, Q25), os itens (pending,
# created_at na ordem do sorteio), e no levantamento drawn, drawn_at e a versão
# dos parâmetros (0 sem versão gravada, A-4). `liraa_survey.drawn` só com ids.
module VectorControl
  module Liraa
    module Draw
      EVENT = "liraa_survey.drawn".freeze
      HOUSEHOLD_START = 1

      module_function

      # -> Result.ok(survey:) | fail(:survey_not_draft | :stratum_out_of_range | :invalid_request, details: { path: })
      def call(survey:, by:, random: SecureRandom)
        parameters = Parameters.current
        LiraaSurvey.transaction(requires_new: true) do
          survey.lock!
          next Result.fail(:survey_not_draft) unless survey.status == "draft"

          strata = survey.strata.order(:created_at, :id).to_a
          plans = plans(strata, parameters)
          next plans if plans.is_a?(Result)

          now = Time.current
          strata.zip(plans).reduce(0) { |offset, (stratum, planned)| write!(stratum, planned, random, now, offset) }
          survey.update!(status: "drawn", drawn_at: now, parameters_version: parameters.version, version: survey.version + 1)
          DomainEvents.publish(EVENT, liraa_survey_id: survey.id, user_id: by.id)
          Result.ok(survey: survey)
        end
      end

      # { city_block_id => [household_id] } da base do sorteio, na ordem (registered_at, id).
      def base(block_ids)
        return {} if block_ids.empty?

        Household.joins("JOIN household_vector_profiles ON household_vector_profiles.household_id = households.id")
                 .joins("JOIN household_versions ON household_versions.household_id = households.id " \
                        "AND household_versions.version = households.version")
                 .where(status: "active", household_vector_profiles: { city_block_id: block_ids })
                 .where("household_versions.property_type IS DISTINCT FROM ?", Catalog::PE_PROPERTY)
                 .order(:registered_at, :id)
                 .pluck("household_vector_profiles.city_block_id", :id)
                 .group_by(&:first).transform_values { |rows| rows.map(&:last) }
      end

      # Os ids na ordem do sorteio (Q18).
      def block_order(block_ids)
        CityBlock.joins(:neighborhood).where(id: block_ids).order("neighborhoods.name", "neighborhoods.id")
                 .natural_number_order.pluck(:id)
      end

      # [{ plan:, blocks: [LiraaStratumBlock em ordem], base:, count: }] | Result de recusa.
      def plans(strata, parameters)
        return Result.fail(:invalid_request, details: { path: "strata" }) if strata.empty?

        rows = LiraaStratumBlock.where(liraa_stratum_id: strata.map(&:id)).to_a
        # Sob a trava do levantamento, os quarteirões FOR SHARE: desativado
        # depois do SaveSurvey (o SaveBlock trava o quarteirão) → o estrato
        # recusado, com o código do SaveSurvey para quarteirão inativo.
        inactive = CityBlock.where(id: rows.map(&:city_block_id)).order(:id).lock("FOR SHARE")
                            .pluck(:id, :active).reject(&:last).map(&:first).to_set
        order = block_order(rows.map(&:city_block_id)).each_with_index.to_h
        base = base(rows.map(&:city_block_id))
        by_stratum = rows.group_by(&:liraa_stratum_id)
        strata.each_with_index.map do |stratum, index|
          blocks = by_stratum.fetch(stratum.id, []).sort_by { |row| order.fetch(row.city_block_id) }
          return Result.fail(:invalid_request, details: { path: "strata[#{index}]" }) if blocks.any? { |row| inactive.include?(row.city_block_id) }

          count = blocks.sum { |row| base.fetch(row.city_block_id, []).size }
          plan = Sample.plan(mode: stratum.mode, households_count: count, blocks_count: blocks.size, parameters: parameters.values)
          return Result.fail(:stratum_out_of_range, details: { path: "strata[#{index}]" }) if plan == :out_of_range

          { plan: plan, blocks: blocks, base: base, count: count }
        end
      end

      # -> o deslocamento seguinte (created_at dos itens em microssegundos a partir de now).
      def write!(stratum, planned, random, now, offset)
        plan = planned[:plan]
        blocks = planned[:blocks]
        start = plan.k == 1 ? 1 : random.rand(1..plan.k)
        stratum.update!(households_count: planned[:count], sample_target: plan.n, block_interval: plan.k, random_start: start,
                        version: stratum.version + 1)
        items = []
        Sample.block_positions(plan: plan, blocks_count: blocks.size, random_start: start).each do |position|
          row = blocks.fetch(position - 1)
          households = planned[:base].fetch(row.city_block_id, [])
          row.update!(drawn: true, household_start: HOUSEHOLD_START, base_household_ids: households, version: row.version + 1)
          Sample.household_positions(plan: plan, households_count: households.size).each do |at|
            items << { liraa_stratum_id: stratum.id, city_block_id: row.city_block_id, household_id: households.fetch(at - 1),
                       position: at, created_at: now + Rational(offset + items.size, 1_000_000), updated_at: now }
          end
        end
        LiraaDrawItem.insert_all!(items) if items.any?
        offset + items.size
      end
      private_class_method :plans, :write!
    end
  end
end
