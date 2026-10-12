require Rails.root.join("lib/pec_simulator").to_s

# Simulador do PEC (ADR 0035), só em development (a rota só é desenhada lá;
# a ação confere de novo). Fica num host próprio (pec-sim.localhost) para
# que o iframe da cidade seja de outra origem, como no PEC real, e o
# frame-ancestors seja provado de verdade. Não resolve cidade pelo host.
module Dev
  class PecSimulatorsController < ActionController::Base
    def show
      return head(:not_found) unless Rails.env.development?

      city = City.find_by!(slug: params.fetch(:city, "maringa"))
      form = PecSimulator.defaults(city).merge(params.permit(:professional, :citizen, :cnes, :minutes_ago).to_h.symbolize_keys)
      url = signed_url_for(city, form) if params[:go]
      render html: PecSimulator.page(city: city, form: form, url: url).html_safe # rubocop:disable Rails/OutputSafety
    end

    private

    def signed_url_for(city, form)
      PecSimulator.signed_url(city: city, professional: form[:professional], citizen: form[:citizen], cnes: form[:cnes],
                              at: form[:minutes_ago].to_i.minutes.ago)
    end
  end
end
