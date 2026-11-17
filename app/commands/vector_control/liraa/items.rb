# Estado do imóvel sorteado do LIRAa pelo boletim (módulo 35a, ADR 0054;
# contrato §3.11 e §7; plano, Review Focus 1 e 4; Q16(c), Q20(1), W-13).
# Quem chama já travou o item FOR UPDATE (depois do domicílio e do perfil;
# HomeVisits::Record e HomeVisits::Withdraw) e está na transação da visita.
#   - inspected!: `worked` → inspected; `closed`/`refused`/`vacant` →
#     substituted (Q20(1): o manual conta o imóvel vago como fechado) e o
#     substituto (substitute!);
#   - substitute!: o levantamento FOR SHARE (o fechamento, FOR UPDATE, espera)
#     e o estrato FOR NO KEY UPDATE (duas substituições no mesmo estrato não
#     escolhem o mesmo imóvel; o INSERT dos itens, FOR KEY SHARE, não espera).
#     Só em levantamento sorteado e uma vez por item (Review Focus 1: a
#     retirada e uma nova recusa não criam outro; idx_liraa_draw_items_substitute
#     garante no banco). O candidato sai SÓ da base do quarteirão na hora do
#     sorteio (Q25: liraa_stratum_blocks.base_household_ids, gravada pelo
#     Liraa::Draw; o esquema não registra quando o imóvel entrou no
#     quarteirão, então a base é guardada): nunca o cadastrado depois do
#     sorteio nem o que mudou para o quarteirão depois dele. Na ordem dessa
#     base, o imóvel imediatamente anterior, depois o posterior, alternando
#     para fora (Q16(c)), só entre os que ainda não são item do estrato e
#     seguem na base de hoje (ativos, no quarteirão, sem PE). Nasce pending
#     com substitute_of_id e a posição na base do sorteio; sem candidato, nada
#     (o quarteirão fica com um a menos: `missing` no Liraa::Index);
#   - released!: a visita retirada devolve o item a pending; o substituto,
#     inspecionado ou não, fica como está (W-13). Levantamento fechado não
#     muda (trigger): o item fica.
# version + 1 a cada mudança (o feed do app segue updated_at).
module VectorControl
  module Liraa
    module Items
      SUBSTITUTED_SITUATIONS = (Catalog::PENDING_SITUATIONS + %w[vacant]).freeze
      # As situações que mudam o item (todas, pela Q20(1)): só a inspeção com
      # uma delas devolve o item na retirada, e só ela o mantém usado.
      MOVING_SITUATIONS = ([ "worked" ] + SUBSTITUTED_SITUATIONS).freeze

      module_function

      def inspected!(item, situation:)
        status = if situation == "worked" then "inspected"
                 elsif SUBSTITUTED_SITUATIONS.include?(situation) then "substituted"
                 end
        return item if status.nil? || item.status != "pending"

        item.update!(status: status, version: item.version + 1)
        substitute!(item) if status == "substituted"
        item
      end

      # -> LiraaDrawItem (o substituto) | nil.
      def substitute!(item)
        stratum = LiraaStratum.find(item.liraa_stratum_id)
        return nil unless LiraaSurvey.lock("FOR SHARE").where(id: stratum.liraa_survey_id).pick(:status) == "drawn"

        LiraaStratum.lock("FOR NO KEY UPDATE").where(id: stratum.id).pick(:id)
        return nil if LiraaDrawItem.exists?(substitute_of_id: item.id)

        order = LiraaStratumBlock.where(liraa_stratum_id: stratum.id, city_block_id: item.city_block_id).pick(:base_household_ids)
        index = order&.index(item.household_id)
        return nil unless index

        current = Draw.base([ item.city_block_id ]).fetch(item.city_block_id, []).to_set
        taken = LiraaDrawItem.where(liraa_stratum_id: stratum.id).pluck(:household_id).to_set
        candidate = (1...order.size).lazy.flat_map { |step| [ index - step, index + step ] }
                                    .find { |at| at.between?(0, order.size - 1) && current.include?(order[at]) && !taken.include?(order[at]) }
        return nil unless candidate

        LiraaDrawItem.create!(liraa_stratum_id: stratum.id, city_block_id: item.city_block_id, household_id: order[candidate],
                              position: candidate + 1, status: "pending", substitute_of_id: item.id)
      end

      def released!(item)
        return item if item.status == "pending" || survey_status(item) == "closed"

        item.update!(status: "pending", version: item.version + 1)
        item
      end

      def survey_status(item) = LiraaStratum.joins(:liraa_survey).where(id: item.liraa_stratum_id).pick("liraa_surveys.status")
    end
  end
end
