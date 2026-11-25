# GET /pharmacy/bnafar/pendencies?location_id=&code= (módulo 27b; contrato §3,
# §6; Q16, Q22): o que impede o envio, calculado na leitura (Bnafar::Pendencies.
# current), sem pessoa. `{ items: [{ code, stock_location_id, location_name,
# item_key, item_label, stock_lot_id, fields }], counts: { code => n } }`;
# `counts` é por código, depois do filtro de local e antes do de código (as
# abas da tela). Exige só o estoque de um domínio utilizável, NUNCA o `bnafar`
# (Q22): sem ele, a conta é feita contra os domínios de estoque utilizáveis,
# como se o envio estivesse ligado, e o `domain_off` é omitido. Com o `bnafar`
# utilizável, o domínio de estoque não ligado ao envio vira `domain_off`.
# Quem: `municipal_admin` ou `stock_keeper` de qualquer local.
module Pharmacy
  module Bnafar
    class PendenciesController < ::Pharmacy::BaseController
      include ::BnafarReader

      skip_before_action :require_pharmacy!
      before_action :require_stock_feature!

      def index
        return unless bnafar_reader!
        return unless query_only!(:location_id, :code)
        return render_refusal("location_id") if params.key?(:location_id) && !uuid?(params[:location_id])
        return render_refusal("code") if params.key?(:code) && !::Bnafar::Catalog::PENDENCY_CODES.include?(params[:code])

        found = ::Bnafar::Pendencies.current(domains_all: usable_domains, domains_on: enabled_domains, now: Time.current)
        found = found.select { |row| row.stock_location_id == params[:location_id] } if params.key?(:location_id)
        counts = found.group_by(&:code).transform_values(&:size)
        found = found.select { |row| row.code == params[:code] } if params.key?(:code)
        render json: { items: found.map(&:to_h), counts: counts }
      end

      private

      def usable_domains = Stock::Domain::FEATURES.keys.select { |domain| stock_domain_usable?(domain) }

      # nil quando o `bnafar` não está utilizável (sem `domain_off`).
      def enabled_domains = ::Bnafar::Gate.usable?(Current.city) ? ::Bnafar::Gate.domains(Current.city) : nil
    end
  end
end
