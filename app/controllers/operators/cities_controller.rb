# Provisionamento de cidade pelo console (spec banco-por-cidade §4, Plano 4):
#
#   POST /cities { slug, name, uf, ibge_code, admin_email, alert_email } → 202 { id }
#   GET  /cities/:id                                                     → 200 { id, slug, status, schema_version }
#   GET  /cities                                                        → 200 { data: [...] }
#
# O POST só registra e enfileira (ProvisionCity): quem cria o banco é o worker. A
# resposta é só o id — o token do convite nunca volta para o console, vai por
# e-mail para o primeiro municipal_admin. Sem CITY_DATABASE_HOST (produção) → 503
# { error: "misconfigured" }.
module Operators
  class CitiesController < BaseController
    # GET /cities — catálogo para o console (Plano 6). Só o que vive na
    # plataforma: nada aqui abre conexão de cidade, então a lista continua
    # barata com N cidades. Métrica por cidade é dentro da cidade (spec §5: o
    # console perde a visão cross-tenant).
    def index
      rows = City.order(created_at: :desc).map do |city|
        {
          id: city.id, slug: city.slug, name: city.name, uf: city.uf,
          status: city.status, schema_version: city.schema_version,
          created_at: city.created_at.iso8601
        }
      end
      render json: { data: rows }
    end

    def create
      result = ProvisionCity.call(
        slug: params[:slug], name: params[:name], uf: params[:uf], ibge_code: params[:ibge_code],
        admin_email: params[:admin_email], alert_email: params[:alert_email], by: current_operator
      )
      return render(json: { id: result.payload[:city].id }, status: :accepted) if result.ok?
      return render(json: { error: "misconfigured" }, status: :service_unavailable) if result.reason == :misconfigured

      status = result.reason == :city_exists ? :conflict : :unprocessable_entity
      render json: { error: result.reason.to_s, message: result.message }, status: status
    end

    def show
      city = City.find_by(id: params[:id].to_s)
      return head(:not_found) unless city

      render json: { id: city.id, slug: city.slug, status: city.status, schema_version: city.schema_version }
    end
  end
end
