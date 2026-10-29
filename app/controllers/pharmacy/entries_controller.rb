# POST /pharmacy/receipts e POST /pharmacy/openings (contrato §3 e H12): entrada
# por nota ou doação (almoxarife do local) e inventário de abertura
# (almoxarife ou farmacêutico do local). 201 com o objeto da entrada, SEM
# envelope. Sem step-up: ele só existe no admin e nos ajustes.
#
# Ordem: o local (422 se não existir), o papel (403 sozinho, antes de validar
# qualquer coisa), local ativo (409 cedo, como os mínimos; o comando confere de
# novo sob trava), `document.kind` e então o comando, que junta todas as recusas
# em `problems`. O catálogo da plataforma é lido AQUI, fora da transação.
module Pharmacy
  class EntriesController < BaseController
    RECEIPT_KINDS = %w[invoice donation].freeze

    before_action :load_location

    def receipt
      return forbid unless allowed?(%w[stock_keeper])
      return render_error(:location_inactive, :conflict) unless @location.active

      document = body_param("document")
      return render_invalid("document") unless document.is_a?(Hash)
      return render_invalid("document.kind") unless RECEIPT_KINDS.include?(document["kind"])

      record(document["kind"])
    end

    def opening
      return forbid unless allowed?(%w[stock_keeper pharmacist])
      return render_error(:location_inactive, :conflict) unless @location.active

      record("opening")
    end

    private

    def load_location
      id = body_param("location_id")
      @location = uuid?(id) ? StockLocation.find_by(id: id) : nil
      render_invalid("location_id") unless @location
    end

    def allowed?(roles) = Access.allowed?(user: Current.user, location: @location, roles: roles)

    def record(kind)
      items = body_param("items")
      result = RecordEntry.call(location: @location, kind: kind, document: body_param("document"), items: items, by: Current.user,
                                catalog: catalog_for(items))
      return render_failure(result) if result.failure?

      entry = result.payload.fetch(:entry)
      movements = result.payload.fetch(:movements)
      catalog = Json.catalog_for(movements.map(&:catalog_item_id))
      render json: Json.entry(entry, movements: movements, catalog: catalog), status: :created
    end

    # Itens do catálogo das linhas, numa consulta (só os ids que parecem uuid e
    # só as primeiras linhas: o resto o comando recusa por tamanho).
    def catalog_for(items)
      return {} unless items.is_a?(Array)

      ids = items.first(Catalog::MAX_ENTRY_ITEMS).filter_map { |row| row["catalog_item_id"] if row.is_a?(Hash) && uuid?(row["catalog_item_id"]) }
      Json.catalog_for(ids)
    end
  end
end
