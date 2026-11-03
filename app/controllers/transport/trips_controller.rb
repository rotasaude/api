# Viagens da central (contrato §4; T4, T19): GET /transport/trips?date=&vehicle_id=
# (`date` obrigatória), POST, PATCH /:id, POST /:id/confirm e /:id/cancel. Só
# a central (transport_dispatcher); motorista e comissão → 403 missing_role.
# Viagem de id desconhecido → 404. Recusas no formato uniforme.
module Transport
  class TripsController < BaseController
    before_action { forbid unless Access.dispatcher?(Current.user) }
    before_action :load_trip, only: %i[update confirm cancel]

    def index
      return unless query_only!(:date, :vehicle_id)

      date = Support.date(params[:date])
      return render_refusal("date") unless date

      scope = TransportTrip.where(date: date)
      if params.key?(:vehicle_id)
        return render_refusal("vehicle_id") unless uuid?(params[:vehicle_id])

        scope = scope.where(transport_vehicle_id: params[:vehicle_id])
      end
      trips = scope.includes(:transport_trip_stops, :transport_vehicle, transport_driver: :user).order(:departure_at, :id)
      render json: { items: trips.map { |trip| Json.trip(trip) } }
    end

    def create
      respond(SaveTrip.call(attrs: body, by: Current.user), status: :created)
    end

    def update
      respond(SaveTrip.call(attrs: body, by: Current.user, trip: @trip))
    end

    def confirm
      respond(ConfirmTrip.call(trip: @trip, by: Current.user))
    end

    def cancel
      respond(CancelTrip.call(trip: @trip, reason: body_param("reason"), by: Current.user))
    end

    private

    def load_trip
      @trip = uuid?(params[:id]) ? TransportTrip.find_by(id: params[:id]) : nil
      not_found unless @trip
    end

    def respond(result, status: :ok)
      return render_failure(result) if result.failure?

      render json: Json.trip(result.payload.fetch(:trip)), status: status
    end
  end
end
