# GET /admin/api/municipalities — catálogo para o seletor de escopo. O escopo é
# a cidade do host: devolve só ela (spec banco-por-cidade §5 — sem visão
# cross-tenant).
class Admin::Api::MunicipalitiesController < Admin::Api::BaseController
  def index
    render json: { data: [ city_descriptor ], as_of: Time.current.iso8601 }
  end

  private

  # Catálogo do seletor: id = slug, name = "Nome · UF". Forma própria deste
  # endpoint, fora do contrato de sessão (o envelope usa `scope.city`).
  def city_descriptor
    city = Current.city
    {
      id: city.slug,
      slug: city.slug,
      name: [ city.name, city.uf ].compact.join(" · "),
      uf: city.uf
    }
  end
end
