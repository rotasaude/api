# Passageiros da viagem (contrato §4; §14 T19, T23): POST
# /transport/trips/:id/passengers → 201 <passenger>; DELETE
# /transport/trips/:id/passengers/:pid { reason } → 200 <trip> (lotação
# atualizada). Só a central; viagem ou passageiro (desta viagem) desconhecido
# → 404. Dado do paciente só no corpo.
module Transport
  class PassengersController < BaseController
    before_action { forbid unless Access.dispatcher?(Current.user) }
    before_action :load_trip

    def create
      return unless query_only!

      result = AddPassenger.call(trip: @trip, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.passenger(result.payload.fetch(:passenger)), status: :created
    end

    def destroy
      return unless query_only!

      passenger = uuid?(params[:passenger_id]) ? @trip.transport_trip_passengers.find_by(id: params[:passenger_id]) : nil
      return not_found unless passenger

      result = RemovePassenger.call(passenger: passenger, reason: body_param("reason"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.trip(@trip.reload)
    end

    private

    def load_trip
      @trip = uuid?(params[:id]) ? TransportTrip.find_by(id: params[:id]) : nil
      not_found unless @trip
    end
  end
end
