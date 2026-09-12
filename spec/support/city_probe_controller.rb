# Controller usado apenas pelo spec de resolução. Fica em support para não
# poluir app/.
class CityProbeController < ActionController::API
  include CityResolution

  def show
    render json: {
      city: Current.city&.slug,
      database: CityRecord.connection_db_config.database
    }
  end
end
