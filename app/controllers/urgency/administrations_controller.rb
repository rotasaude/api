# Checagem da medicação (ADR 0050; contrato §6 e §12 Q5, Q6; plano, Desvios 6
# a 8): POST /urgency/administrations { prescription_item_id, scheduled_at?,
# status, reason?, administered_at?, stock_lot_id?, stock_quantity? } → 201
# `{ administration: <adm>, shortfall: null | { cause } }` pelo
# Urgency::RecordAdministration. Só do corpo (chave desconhecida ou query →
# 422 com o nome da chave). O interruptor de estoque (plataforma) é lido AQUI,
# fora da transação da cidade.
module Urgency
  class AdministrationsController < BaseController
    KEYS = %w[prescription_item_id scheduled_at status reason administered_at stock_lot_id stock_quantity].freeze

    def create
      return unless query_only! && only_keys!(KEYS)

      result = RecordAdministration.call(attrs: body, by: Current.user, stock: StockGate.usable?(Current.city))
      return render_failure(result) if result.failure?

      administration = UrgencyAdministration.includes(:stock_lot, recorded_by_user: :professional).find(result.payload.fetch(:administration).id)
      shortfall = result.payload[:shortfall]
      render json: { administration: Schedule.administration(administration), shortfall: shortfall && { cause: shortfall.cause } },
             status: :created
    end
  end
end
