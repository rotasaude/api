# GET/POST/PATCH /regulation/admin/offers[/:id] (contrato §6): ofertas mensais
# por prestador e alvo, com a cota. `GET ?month=&target_code=&provider_id=`
# (mês padrão = o corrente no fuso da cidade) devolve `<offer>` com `used` e
# `available`. Leitura: municipal_admin ou care_regulator; escrita só
# municipal_admin, com step-up.
module CareRegulation
  module Admin
    class OffersController < BaseController
      before_action { forbid unless admin? || regulator? }
      before_action(only: %i[create update]) { forbid unless admin? }
      before_action :require_step_up!, only: %i[create update]

      def index
        month = month_filter
        return render_path_error("month") unless month

        provider_id = params[:provider_id].presence
        return render_path_error("provider_id") if provider_id && !uuid?(provider_id)

        offers = CareOffer.where(month: month)
        offers = offers.where(target_code: params[:target_code]) if params[:target_code].is_a?(String) && params[:target_code].present?
        offers = offers.where(care_provider_id: provider_id) if provider_id
        offers = offers.joins(:care_provider).preload(:care_provider).order("care_providers.name", :target_code, :id).to_a
        render json: { offers: serialize(offers) }
      end

      def create
        result = SaveOffer.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: serialize([ result.payload.fetch(:offer) ]).first, status: :created
      end

      def update
        offer = uuid?(params[:id]) && CareOffer.find_by(id: params[:id])
        return not_found unless offer

        result = SaveOffer.call(attrs: body, by: Current.user, offer: offer)
        return render_failure(result) if result.failure?

        render json: serialize([ result.payload.fetch(:offer) ]).first
      end

      private

      # `month` padrão = mês corrente; texto fora de AAAA-MM → nil.
      def month_filter
        raw = params[:month]
        return Time.zone.today.beginning_of_month if raw.blank?
        return nil unless raw.is_a?(String) && raw.match?(Catalog::MONTH)

        Date.new(raw[0, 4].to_i, raw[5, 2].to_i, 1)
      end

      def render_path_error(path) = render(json: { error: "invalid_request", path: path }, status: :unprocessable_entity)

      # used numa consulta só e os nomes dos alvos em lote.
      def serialize(offers)
        used = Quota.used(offers.map(&:id))
        names = Targets.names_for(offers.map { |offer| [ offer.target_type, offer.target_code ] }.uniq)
        offers.map do |offer|
          Json.offer(offer, used: used.fetch(offer.id), name: names[[ offer.target_type, offer.target_code ]])
        end
      end
    end
  end
end
