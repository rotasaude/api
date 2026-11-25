# PATCH /pharmacy/lots/:id/bnafar (módulo 27b, Task 5; contrato §2; Q16, Q23):
# complemento dos dados BNAFAR do lote. Corpo `{ location_id, expected_version,
# ...campos }`. Exige só o estoque do domínio do local (nunca o interruptor
# `bnafar`: o dado de origem se completa antes de ligar o envio). Quem pode:
# `stock_keeper` ou `pharmacist` do local (com movimento do lote ali; senão
# 404) ou `municipal_admin`. Sem step-up, sem dado de pessoa.
#
# Ordem: local (422 location_id), interruptor do domínio, papel (403), lote
# (404), versão (422 expected_version_required) e então o comando.
module Pharmacy
  class LotComplementsController < BaseController
    ROLES = %w[stock_keeper pharmacist].freeze

    skip_before_action :require_pharmacy!
    before_action :require_stock_feature!

    def update
      location = body_location_or_refuse or return
      return unless stock_feature_for!(location)
      return forbid unless admin? || Access.allowed?(user: Current.user, location: location, roles: ROLES)

      lot = uuid?(params[:id]) ? StockLot.find_by(id: params[:id]) : nil
      return not_found unless lot && Stock::Domain.allows?(location, lot) && (admin? || present_at?(location, lot))

      result = ::Bnafar::CompleteLot.call(lot: lot, attrs: body.except("location_id", "expected_version"),
                                          expected_version: body_param("expected_version"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: { id: lot.id, bnafar: ::Bnafar::LotFields.lot_json(result.payload.fetch(:lot)) }
    end

    private

    # O lote é conhecido no local: tem movimento nele.
    def present_at?(location, lot) = StockMovement.where(stock_location_id: location.id, stock_lot_id: lot.id).exists?
  end
end
