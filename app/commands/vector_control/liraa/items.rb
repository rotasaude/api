# Estado do imóvel sorteado do LIRAa pelo boletim (módulo 35a, ADR 0054;
# contrato §3.11 e §7; plano, Review Focus 1 e 4, W-13). Quem chama já travou
# o item FOR UPDATE (depois do domicílio e do perfil; HomeVisits::Record e
# HomeVisits::Withdraw) e está na transação da visita.
#   - inspected!: `worked` → inspected; `closed`/`refused` → substituted (o
#     substituto nasce na Task 10, `substitute!`); `vacant` não muda o item
#     (o contrato só substitui fechado e recusa);
#   - released!: a visita retirada devolve o item a pending; o substituto,
#     inspecionado ou não, fica como está (W-13). Levantamento fechado não
#     muda (trigger): o item fica.
# version + 1 a cada mudança (o feed do app segue updated_at).
module VectorControl
  module Liraa
    module Items
      module_function

      def inspected!(item, situation:)
        status = if situation == "worked" then "inspected"
                 elsif Catalog::PENDING_SITUATIONS.include?(situation) then "substituted"
                 end
        return item if status.nil? || item.status != "pending"

        item.update!(status: status, version: item.version + 1)
        item
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
