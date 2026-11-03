# Lista de passageiros em PDF (contrato §4): GET /transport/trips/:id/manifest.pdf,
# só a central. Sem dado clínico, CPF nem CNS; sem trilha, sem log.
module Transport
  class ManifestsController < BaseController
    before_action { forbid unless Access.dispatcher?(Current.user) }

    def show
      return unless query_only!

      trip = uuid?(params[:id]) ? TransportTrip.includes(:transport_trip_stops, :transport_vehicle, transport_driver: :user).find_by(id: params[:id]) : nil
      return not_found unless trip

      response.headers["Cache-Control"] = "no-store"
      send_data ManifestPdf.call(trip), type: "application/pdf", disposition: "inline", filename: "passageiros.pdf"
    end
  end
end
