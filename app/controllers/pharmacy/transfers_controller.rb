# Transferência do central para a unidade (contrato §5 e H2/H5/H12; plano do
# api, Task 6). Respostas SEM envelope, na forma <transfer> (Pharmacy::Json).
#
# Quem pode: enviar, o `stock_keeper` do central; receber, `stock_keeper`,
# `pharmacist` ou `pharmacy_assistant` do DESTINO. Ver (detalhe e lista): quem
# tem algum papel na origem ou no destino.
#
# Ordem (como as entradas): papel (403 sozinho, antes de validar o corpo) → o
# que o corpo nomeia → o comando, que junta todas as recusas em `problems`
# (inclusive `to_location_id` inexistente e as estruturais). Todo 422 traz
# `problems` com pelo menos um problema. Recurso da URL
# (`transfers/:id`) de outro escopo → 404. O catálogo da plataforma é lido
# AQUI, fora da transação.
module Pharmacy
  class TransfersController < BaseController
    SENDER_ROLES = %w[stock_keeper].freeze
    RECEIVER_ROLES = %w[stock_keeper pharmacist pharmacy_assistant].freeze
    PRELOAD = [ { from_location: :health_unit }, { to_location: :health_unit }, { items: :stock_lot } ].freeze

    before_action :load_transfer, only: %i[show receive]

    def create
      central = StockLocation.find_by(kind: "central")
      return forbid unless central && Access.allowed?(user: Current.user, location: central, roles: SENDER_ROLES)

      # Destino que o corpo não nomeia, não é uuid ou não existe segue como nil:
      # o comando recusa (`to_location_id`) junto das linhas.
      id = body_param("to_location_id")
      to = uuid?(id) ? StockLocation.find_by(id: id) : nil
      return render_failure(Result.fail(:location_inactive, details: { path: "from" })) unless central.active
      return render_failure(Result.fail(:location_inactive, details: { path: "to_location_id" })) if to&.unit? && !to.active

      result = SendTransfer.call(from: central, to: to, items: body_param("items"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: present_one(result.payload.fetch(:transfer)), status: :created
    end

    def receive
      return forbid unless receiver?

      result = ReceiveTransfer.call(transfer: @transfer, items: body_param("items"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: present_one(result.payload.fetch(:transfer), reasons: true)
    end

    def show
      render json: present_many([ @transfer ], reasons: receiver?).sole
    end

    # `location_id` obrigatório e do usuário (algum papel nele): as transferências
    # que saíram ou chegaram ali, mais novas primeiro.
    def index
      return unless query_only!(:location_id, :status, :before, :limit)

      location = listed_location
      return render_refusal("location_id") unless location
      return forbid if Access.roles_at(user: Current.user, location: location).empty?

      status = params[:status]
      return render_refusal("status") if params.key?(:status) && !Catalog::TRANSFER_STATUSES.include?(status)

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

      scope = StockTransfer.where("from_location_id = :id OR to_location_id = :id", id: location.id)
      scope = scope.where(status: status) if status
      scope = scope.where("(stock_transfers.created_at, stock_transfers.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last) if cursor
      rows = scope.includes(*PRELOAD).order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { transfers: present_many(page),
                     next_before: rows.size > limit ? Cursor.encode([ page.last.created_at.utc.iso8601(6), page.last.id ]) : nil }
    end

    private

    # Transferência da URL, só se o usuário tem algum papel na origem ou no
    # destino; senão 404 (não diz que existe).
    def load_transfer
      @transfer = uuid?(params[:id]) ? StockTransfer.includes(*PRELOAD).find_by(id: params[:id]) : nil
      return not_found unless @transfer
      return not_found if [ @transfer.from_location, @transfer.to_location ].all? { |loc| Access.roles_at(user: Current.user, location: loc).empty? }
    end

    def receiver? = Access.allowed?(user: Current.user, location: @transfer.to_location, roles: RECEIVER_ROLES)

    def listed_location
      raw = params[:location_id]
      uuid?(raw) ? StockLocation.find_by(id: raw) : nil
    end

    # Cursor [iso8601(6), id] com a data legível e o id uuid.
    def valid_cursor?(cursor)
      return false unless cursor && cursor.size == 2 && uuid?(cursor.last)

      Time.iso8601(cursor.first)
      true
    rescue ArgumentError
      false
    end

    # A transferência recém-gravada, relida com os locais e os lotes.
    def present_one(transfer, reasons: false)
      present_many([ StockTransfer.includes(*PRELOAD).find(transfer.id) ], reasons: reasons).sole
    end

    # <transfer> de cada uma, com o catálogo lido numa consulta só.
    def present_many(transfers, reasons: false)
      catalog = Json.catalog_for(transfers.flat_map { |transfer| transfer.items.map { |item| item.stock_lot.catalog_item_id } })
      transfers.map { |transfer| Json.transfer(transfer, catalog: catalog, reasons: reasons) }
    end
  end
end
