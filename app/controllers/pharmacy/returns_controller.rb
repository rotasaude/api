# POST /pharmacy/returns (contrato H2/H12; plano do api, Desvio 12; ruling do
# controlador): `{ location_id, dispensation_item_id, quantity, reason }`, só no
# corpo JSON (chave na query → 422). `pharmacist` ou `pharmacy_assistant` do
# local `unit` ativo (403 missing_role sozinho); o item dispensado precisa ser
# de uma dispensação DESSE local (outro local ou inexistente → 404: não diz que
# existe). Item CONTROLADO (o critério da dispensação, RecordReturn.controlled?)
# só o farmacêutico devolve: o auxiliar recebe 403
# controlled_requires_pharmacist, sozinho. Sem step-up, como a dispensação.
#
# 201 com o <dispensation> inteiro atualizado (itens com `returned_total`), sem
# envelope. 422 com `problems`: invalid_quantity, invalid_reason, lot_expired,
# return_exceeds. Sem trilha nova (a dispensação mostrada é a do próprio local,
# que o usuário acabou de abrir pelo histórico, que já deixou a trilha).
module Pharmacy
  class ReturnsController < BaseController
    def create
      location = body_location_or_refuse
      return unless location
      return forbid unless dispenser_at?(location)
      return unless query_only!

      id = body_param("dispensation_item_id")
      return render_refusal("dispensation_item_id") unless uuid?(id)

      item = DispensationItem.includes(:dispensation, :stock_lot).find_by(id: id)
      return not_found unless item && item.dispensation.stock_location_id == location.id
      return forbid("controlled_requires_pharmacist") if !pharmacist_at?(location) && RecordReturn.controlled?(item)

      result = RecordReturn.call(location: location, dispensation_item: item, quantity: body_param("quantity"), reason: body_param("reason"),
                                 by: Current.user)
      return render_failure(result) if result.failure?

      saved = Dispensation.includes(*Json::DISPENSATION_PRELOAD).find(item.dispensation_id)
      catalog = Json.catalog_for(saved.items.map(&:catalog_item_id))
      render json: Json.dispensation(saved, catalog: catalog, patient: Patient.find(saved.patient_id)), status: :created
    end

    private

    def pharmacist_at?(location) = Access.allowed?(user: Current.user, location: location, roles: %w[pharmacist])
  end
end
