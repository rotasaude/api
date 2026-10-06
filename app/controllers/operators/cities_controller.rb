# Provisionamento de cidade pelo console (spec banco-por-cidade §4, Plano 4):
#
#   POST /cities { slug, name, uf, ibge_code, admin_email, alert_email, time_zone? } → 202 { id }
#   GET  /cities/:id                                                     → 200 { id, slug, status, schema_version, ... }
#   PATCH /cities/:id/record_settings { record_mode?, ibge_code?, pec_url? } → 200 { city }
#   GET  /cities                                                        → 200 { data: [...] }
#
# O POST só registra e enfileira (ProvisionCity): quem cria o banco é o worker. A
# resposta é só o id — o token do convite nunca volta para o console, vai por
# e-mail para o primeiro municipal_admin. Sem CITY_DATABASE_HOST (produção) → 503
# { error: "misconfigured" }.
module Operators
  class CitiesController < BaseController
    # GET /cities — catálogo para o console (Plano 6). ADR 0028: cada cidade ativa abre a conexão dela uma vez (IBGE e credenciais, para ibge_code e features); cidade que não responde sai com city_reachable false, nunca derruba a lista.
    def index
      render json: { data: City.order(created_at: :desc).map { |city| city_json(city) } }
    end

    def create
      result = ProvisionCity.call(
        slug: params[:slug], name: params[:name], uf: params[:uf], ibge_code: params[:ibge_code],
        admin_email: params[:admin_email], alert_email: params[:alert_email], by: current_operator,
        time_zone: params[:time_zone].presence || ProvisionCity::DEFAULT_TIME_ZONE
      )
      return render(json: { id: result.payload[:city].id }, status: :accepted) if result.ok?
      return render(json: { error: "misconfigured" }, status: :service_unavailable) if result.reason == :misconfigured

      status = result.reason == :city_exists ? :conflict : :unprocessable_entity
      render json: { error: result.reason.to_s, message: result.message }, status: status
    end

    def show
      city = City.find_by(id: params[:id].to_s)
      return head(:not_found) unless city

      render json: city_json(city)
    end

    def record_settings
      city = City.find_by(id: params[:id].to_s)
      return render(json: { error: "not_found" }, status: :not_found) unless city

      result = UpdateCityRecordSettings.call(city: city, attrs: request.request_parameters)
      if result.failure?
        status = result.reason == :city_unreachable ? :service_unavailable : :unprocessable_entity
        return render(json: { error: result.reason.to_s }, status: status)
      end

      render json: { city: city_json(city.reload) }
    end

    private

    # Mesmo formato na lista, na ficha e no PATCH (contratos §4.2).
    def city_json(city)
      state = Platform::Features.city_state(city)
      {
        id: city.id, slug: city.slug, name: city.name, uf: city.uf, status: city.status,
        schema_version: city.schema_version, time_zone: city.time_zone, created_at: city.created_at.iso8601,
        record_mode: city.record_mode, pec_url: city.pec_url, ibge_code: state&.dig(:ibge_code),
        city_reachable: !state.nil?,
        features: Platform::Features.summary(city, state: state).map { |f| f.slice(:key, :enabled, :usable, :missing) }
      }
    end
  end
end
