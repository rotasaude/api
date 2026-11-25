# GET /pharmacy/bnafar/pendencies?location_id=&code= (módulo 27b; contrato §3,
# §6; Q16, Q22): o que impede o envio, calculado na leitura (Bnafar::Pendencies.
# current), sem pessoa (Q32 leitores; Q33 página). `{ items: [{ code,
# stock_location_id, location_name, item_key, item_label, stock_lot_id,
# fields }], next_before, totals: { by_code: { code => n }, by_location:
# { location_id => n } } }`. Página: padrão 50, máximo 100 (`limit`; 101 → 422).
# Ordem e cursor estáveis: (stock_location_id, item_key, stock_lot_id, code); o
# `before` é a quádrupla do último item da página. `totals` não depende da
# página: `by_code` conta depois do filtro de local e antes do de código;
# `by_location`, depois do filtro de código e antes do de local (cada faceta
# ignora o próprio filtro). Exige só o estoque de um domínio utilizável, NUNCA o `bnafar`
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
        return unless query_only!(:location_id, :code, :before, :limit)
        return render_refusal("location_id") if params.key?(:location_id) && !uuid?(params[:location_id])
        return render_refusal("code") if params.key?(:code) && !::Bnafar::Catalog::PENDENCY_CODES.include?(params[:code])

        limit = page_limit or return
        cursor = params.key?(:before) ? ::Pharmacy::Cursor.decode(params[:before]) : nil
        return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_key?(cursor)

        found = ::Bnafar::Pendencies.current(domains_all: usable_domains, domains_on: enabled_domains, now: Time.current)
        in_location = params.key?(:location_id) ? found.select { |row| row.stock_location_id == params[:location_id] } : found
        in_code = params.key?(:code) ? found.select { |row| row.code == params[:code] } : found
        rows = params.key?(:code) ? in_location.select { |row| row.code == params[:code] } : in_location
        rows = rows.sort_by { |row| key_of(row) }
        rows = rows.select { |row| (key_of(row) <=> cursor) == 1 } if cursor
        page = rows.first(limit)
        render json: { items: page.map(&:to_h),
                       next_before: rows.size > limit ? ::Pharmacy::Cursor.encode(key_of(page.last)) : nil,
                       totals: { by_code: in_location.group_by(&:code).transform_values(&:size),
                                 by_location: in_code.group_by(&:stock_location_id).transform_values(&:size) } }
      end

      private

      def key_of(row) = [ row.stock_location_id, row.item_key, row.stock_lot_id, row.code ].map(&:to_s)

      def valid_key?(cursor)
        cursor && cursor.size == 4 && uuid?(cursor.first) && uuid?(cursor[2]) && ::Bnafar::Catalog::PENDENCY_CODES.include?(cursor.last)
      end

      def usable_domains = Stock::Domain::FEATURES.keys.select { |domain| stock_domain_usable?(domain) }

      # nil quando o `bnafar` não está utilizável (sem `domain_off`).
      def enabled_domains = ::Bnafar::Gate.usable?(Current.city) ? ::Bnafar::Gate.domains(Current.city) : nil
    end
  end
end
