# GET/POST/PATCH /regulation/admin/providers[/:id] (contrato §6): prestadores
# da regulação. Leitura: municipal_admin ou care_regulator; escrita só
# municipal_admin, com step-up. Nunca se apaga: desativa-se (`active`).
module CareRegulation
  module Admin
    class ProvidersController < BaseController
      before_action { forbid unless admin? || regulator? }
      before_action(only: %i[create update]) { forbid unless admin? }
      before_action :require_step_up!, only: %i[create update]

      def index
        providers = CareProvider.includes(:health_unit).order(:name, :id)
        render json: { providers: providers.map { |provider| Json.provider(provider) } }
      end

      def create
        result = SaveProvider.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.provider(result.payload.fetch(:provider)), status: :created
      end

      def update
        provider = uuid?(params[:id]) && CareProvider.find_by(id: params[:id])
        return not_found unless provider

        result = SaveProvider.call(attrs: body, by: Current.user, provider: provider)
        return render_failure(result) if result.failure?

        render json: Json.provider(result.payload.fetch(:provider))
      end
    end
  end
end
