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
#
# Módulo 29 (Desvio 5; §15 V4): `from_location_id` opcional no envio (ausente =
# o central de medicamentos; a rede de frio envia só para sala de vacina). O
# interruptor é o do domínio do local (origem no envio; destino na leitura e
# no recebimento); na sala, o papel é o da equipe (Pharmacy::Access): a
# técnica (`vaccinator`) e o responsável (`room_lead`) recebem.
module Pharmacy
  class TransfersController < BaseController
    SENDER_ROLES = %w[stock_keeper].freeze
    RECEIVER_ROLES = %w[stock_keeper pharmacist pharmacy_assistant].freeze
    PRELOAD = [ { from_location: :health_unit }, { to_location: :health_unit }, { items: :stock_lot } ].freeze

    skip_before_action :require_pharmacy!
    before_action :require_stock_feature!
    before_action :load_transfer, only: %i[show receive]

    def create
      from = sender_location or return
      return unless stock_feature_for!(from)
      return forbid unless Access.allowed?(user: Current.user, location: from, roles: SENDER_ROLES)

      # Destino que o corpo não nomeia, não é uuid ou não existe segue como nil:
      # o comando recusa (`to_location_id`) junto das linhas.
      id = body_param("to_location_id")
      to = uuid?(id) ? StockLocation.find_by(id: id) : nil
      return render_failure(Result.fail(:location_inactive, details: { path: "from" })) unless from.active
      if to && to.kind == SendTransfer::DESTINATIONS.fetch(from.kind) && !to.active
        return render_failure(Result.fail(:location_inactive, details: { path: "to_location_id" }))
      end

      result = SendTransfer.call(from: from, to: to, items: body_param("items"), by: Current.user)
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
      return unless stock_feature_for!(location)
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

    # Origem do envio: `from_location_id` do corpo (uuid de local existente de
    # um tipo que envia; senão 422 `from_location_id`) ou, ausente, o central
    # de medicamentos (sem central: 403, como antes). nil = já respondeu.
    def sender_location
      id = body_param("from_location_id")
      if id.nil?
        central = StockLocation.find_by(kind: "central")
        return central if central

        forbid
        return nil
      end
      location = uuid?(id) ? StockLocation.find_by(id: id) : nil
      return location if location && SendTransfer::DESTINATIONS.key?(location.kind)

      render_refusal("from_location_id")
      nil
    end

    # Transferência da URL, só se o usuário tem algum papel na origem ou no
    # destino; senão 404 (não diz que existe). O interruptor é o do domínio do
    # destino (os dois locais são do mesmo domínio).
    def load_transfer
      @transfer = uuid?(params[:id]) ? StockTransfer.includes(*PRELOAD).find_by(id: params[:id]) : nil
      return not_found unless @transfer
      return not_found if [ @transfer.from_location, @transfer.to_location ].all? { |loc| Access.roles_at(user: Current.user, location: loc).empty? }

      stock_feature_for!(@transfer.to_location)
    end

    def receiver? = Access.allowed?(user: Current.user, location: @transfer.to_location, roles: RECEIVER_ROLES)

    def listed_location
      raw = params[:location_id]
      uuid?(raw) ? StockLocation.find_by(id: raw) : nil
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
