# Pendências das séries (contrato §4; T20): GET /transport/pending → `{ items:
# [ { series_id, date, reason } ] }` — as não resolvidas de hoje em diante, por
# data. Só a central. Sem paciente nem destino.
module Transport
  class PendingController < BaseController
    before_action { forbid unless Access.dispatcher?(Current.user) }

    def index
      return unless query_only!

      items = TransportPendingItem.where(resolved_at: nil, date: Time.zone.today..).order(:date, :transport_series_id)
      render json: { items: items.map { |i| { series_id: i.transport_series_id, date: i.date.iso8601, reason: i.reason } } }
    end
  end
end
