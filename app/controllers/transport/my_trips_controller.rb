# Tela do motorista (contrato §5; §14 T19): só o usuário `driver` com cadastro
# ativo (Transport::Access.driver_for; senão 403 missing_role) e só as viagens
# em que ele é o motorista — viagem de outro motorista ou desconhecida → 404.
#   GET  /transport/my_trips?date=        → { items: [<trip>] } (padrão hoje, no fuso da cidade)
#   POST /transport/my_trips/:id/start    → <trip> (Transport::StartTrip)
#   POST /transport/my_trips/:id/attendance { items } → <trip> (Transport::RecordAttendance)
#   POST /transport/my_trips/:id/close    { odometer_start, odometer_end, fuel, expenses } → <trip> (Transport::CloseTrip)
# <passenger> na visão do motorista: sem `cns_masked` nem `has_cpf`; nunca dado clínico.
module Transport
  class MyTripsController < BaseController
    before_action :load_driver
    before_action :load_trip, except: :index

    def index
      return unless query_only!(:date)

      date = params.key?(:date) ? Support.date(params[:date]) : Time.zone.today
      return render_refusal("date") unless date

      trips = TransportTrip.where(transport_driver_id: @driver.id, date: date)
                           .includes(:transport_trip_stops, :transport_vehicle, :transport_trip_log, transport_driver: :user)
                           .order(:departure_at, :id)
      render json: { items: trips.map { |trip| Json.trip(trip, viewer: :driver) } }
    end

    def start
      return unless query_only!

      respond(StartTrip.call(trip: @trip, by: Current.user))
    end

    def attendance
      return unless query_only!

      respond(RecordAttendance.call(trip: @trip, items: body_param("items"), by: Current.user))
    end

    def close
      return unless query_only!

      respond(CloseTrip.call(trip: @trip, attrs: body, by: Current.user))
    end

    private

    def load_driver
      @driver = Access.driver_for(Current.user)
      forbid unless @driver
    end

    def load_trip
      @trip = uuid?(params[:id]) ? TransportTrip.find_by(id: params[:id], transport_driver_id: @driver.id) : nil
      not_found unless @trip
    end

    def respond(result)
      return render_failure(result) if result.failure?

      render json: Json.trip(result.payload.fetch(:trip).reload, viewer: :driver)
    end
  end
end
