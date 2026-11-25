# Saída externa do estoque (módulo 27b, Task 9; contrato §4; Q16). Respostas SEM
# envelope, na forma <external_exit> (Pharmacy::Json). Exige só o estoque do
# domínio do local (`require_stock_feature!` + `stock_feature_for!`), nunca o
# interruptor `bnafar`: os locais de todos os domínios utilizáveis servem.
#
# Quem pode: gravar, o `stock_keeper` do local, com step-up; ler (lista e
# detalhe), o `stock_keeper` do local e o `municipal_admin`. O motivo (texto
# livre) só vai no detalhe e na gravação, nunca na lista.
#
# Ordem de `create`: `location_id` (422 se não existir) → interruptor do domínio
# → papel (403 sozinho, antes de validar o corpo) → step-up (401) → o comando,
# que junta todas as recusas em `problems`. Saída da URL de local sem papel
# (nem admin) → 404. O catálogo da plataforma é lido AQUI, fora da transação.
module Pharmacy
  class ExternalExitsController < BaseController
    WRITER_ROLES = %w[stock_keeper].freeze
    PRELOAD = [ { stock_location: :health_unit }, { items: { stock_lot: :vector_product } } ].freeze

    skip_before_action :require_pharmacy!
    before_action :require_stock_feature!

    def create
      location = body_location_or_refuse or return
      return unless stock_feature_for!(location)
      return forbid unless Access.allowed?(user: Current.user, location: location, roles: WRITER_ROLES)

      require_step_up!
      return if performed?

      result = RecordExternalExit.call(location: location, attrs: body.except("location_id"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: present([ StockExternalExit.includes(*PRELOAD).find(result.payload.fetch(:exit).id) ], reason: true).sole, status: :created
    end

    # `location_id` obrigatório: as saídas do local, mais novas primeiro, sem o motivo.
    def index
      return unless query_only!(:location_id, :before, :limit)

      raw = params[:location_id]
      location = uuid?(raw) ? StockLocation.find_by(id: raw) : nil
      return render_refusal("location_id") unless location
      return unless stock_feature_for!(location)
      return forbid unless reader?(location)

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

      scope = StockExternalExit.where(stock_location_id: location.id)
      scope = scope.where("(stock_external_exits.created_at, stock_external_exits.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last) if cursor
      rows = scope.includes(*PRELOAD).order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { external_exits: present(page),
                     next_before: rows.size > limit ? Cursor.encode([ page.last.created_at.utc.iso8601(6), page.last.id ]) : nil }
    end

    def show
      row = uuid?(params[:id]) ? StockExternalExit.includes(*PRELOAD).find_by(id: params[:id]) : nil
      return not_found unless row && reader?(row.stock_location)
      return unless stock_feature_for!(row.stock_location)

      render json: present([ row ], reason: true).sole
    end

    private

    def reader?(location) = admin? || Access.allowed?(user: Current.user, location: location, roles: WRITER_ROLES)

    # <external_exit> de cada uma, com o catálogo lido numa consulta só.
    def present(rows, reason: false)
      catalog = Json.catalog_for(rows.flat_map { |row| row.items.map { |item| item.stock_lot.catalog_item_id } })
      rows.map { |row| Json.external_exit(row, catalog: catalog, reason: reason) }
    end
  end
end
