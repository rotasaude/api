# Resolve a cidade pelo host ANTES de qualquer query, e executa a ação dentro
# da conexão daquela cidade.
#
# A ordem importa e é o inverso da que TenantScopedRequest usava: primeiro
# resolve a cidade, depois autentica. É isso que torna um cookie de uma cidade
# inútil na vizinha — a sessão é procurada no banco da cidade do host.
module CityResolution
  extend ActiveSupport::Concern

  included do
    around_action :within_city
  end

  class_methods do
    def skip_city_resolution(**options)
      skip_around_action :within_city, **options
    end
  end

  private

  def within_city(&block)
    city = CityCatalog.find_by_host(request.host)

    return render(json: { error: "unknown_city" }, status: :not_found) if city.nil?
    return render(json: { error: "city_suspended" }, status: :forbidden) if city.status == "suspended"
    return render(json: { error: "unknown_city" }, status: :not_found) unless city.servable?

    Current.city = city
    CityConnection.with(city, &block)
  end
end
