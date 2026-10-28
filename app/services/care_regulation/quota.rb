# Cota das ofertas (contrato §13 G1; plano do api, Desvio 3). O usado de uma
# oferta é a contagem das autorizações NÃO liberadas dela (`released_at IS
# NULL`): cancelar libera, falta e atendimento não. `care_offers` não guarda o
# usado. Quem decide sobre a cota (Authorize, SaveOffer) lê sob `FOR UPDATE`
# na oferta; aqui só se conta.
module CareRegulation
  module Quota
    module_function

    # -> { offer_id => Integer } numa consulta só; oferta sem autorização = 0.
    def used(offer_ids)
      ids = Array(offer_ids)
      return {} if ids.empty?

      counts = RegulationAuthorization.unreleased.where(care_offer_id: ids).group(:care_offer_id).count
      ids.index_with { |id| counts.fetch(id, 0) }
    end

    # quantity - used, nunca negativo (uma cota reduzida não pode ficar abaixo
    # do usado, mas dado antigo não pode dar disponível negativo).
    def available(offer, used:) = [ offer.quantity - used, 0 ].max
  end
end
