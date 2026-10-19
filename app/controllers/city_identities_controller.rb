require "aws-sdk-s3" # require: false no Gemfile; as classes de erro precisam existir ao carregar

# Identidade pública da cidade (nome, UF, fuso, órgão de saúde, brasão), lida
# pelo login do dashboard e pelo wpda ANTES de qualquer sessão.
#
# Resolve a cidade só pela plataforma (CityCatalog), sem abrir o banco dela:
# a identidade precisa responder mesmo com o banco da cidade fora do ar ou com
# schema atrasado. Por isso skip_city_resolution. Cidade que não está ativa dá
# 404 igual a host desconhecido — não revela suspensa/em provisionamento.
class CityIdentitiesController < ApplicationController
  skip_city_resolution

  # Mesmo molde do MfaController: resolve Rails.cache a cada requisição, o que
  # torna o teto exercitável em spec. Só o JSON conta; a imagem é cacheada.
  module RateLimitStore
    def self.increment(...) = Rails.cache.increment(...)
  end

  STORAGE_ERRORS = [Aws::Errors::ServiceError, Seahorse::Client::NetworkingError, SystemCallError, IOError, Timeout::Error].freeze

  before_action :resolve_city

  rate_limit to: 120, within: 1.minute, only: :show, name: "city_identity",
             by: -> { request.remote_ip }, store: RateLimitStore,
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def show
    expires_in 5.minutes, public: true
    render json: {
      name: @city.name, uf: @city.uf, time_zone: @city.time_zone,
      health_department_name: @city.health_department_name,
      coat_of_arms_url: @city.coat_of_arms_path
    }
  end

  def coat_of_arms
    return head(:not_found) unless @city.coat_of_arms.attached?

    blob = @city.coat_of_arms.blob
    # v velho/arbitrário não pode ganhar resposta imutável de 1 ano.
    return head(:not_found) if params[:v].present? && params[:v].to_s != blob.checksum

    data = blob.download
    response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data data, type: blob.content_type, disposition: "inline"
  rescue ActiveStorage::FileNotFoundError
    head :not_found
  rescue *STORAGE_ERRORS
    response.headers["Cache-Control"] = "no-store"
    head :service_unavailable
  end

  private

  def resolve_city
    found = CityCatalog.find_by_host(request.host)
    return render(json: { error: "unknown_city" }, status: :not_found) unless found&.status == "active"

    # O catálogo guarda o City por 30 s; recarregar evita servir o checksum
    # velho logo depois de trocar o brasão.
    @city = City.find(found.id)
  end
end
