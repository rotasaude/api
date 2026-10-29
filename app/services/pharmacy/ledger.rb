# Livro de movimentos do estoque (ADR 0045). O saldo nunca é coluna: é a soma
# de stock_movements por (local, lote). Toda escrita de estoque passa por aqui.
#
# Concorrência. A conta da aplicação (saldo + movimento >= 0) só vale com o
# lote travado: duas saídas do último frasco, cada uma lendo 10 antes da outra
# gravar, passariam as duas. O trigger do banco (rota_stock_balance_guard) é o
# cinto, não a trava. A ordem de travas do módulo é LOTES → LOCAL → DOCUMENTO
# (receita, transferência ou ajuste):
#
#   1. lock_lots!   — FOR UPDATE em TODOS os lotes que a escrita vai usar, em
#      ordem de id. O FK de stock_movements pede FOR KEY SHARE no lote, que
#      conflita com FOR UPDATE: lote usado sem estar na lista travada abre
#      caminho para deadlock. Duas operações com lotes em ordem inversa nunca
#      se travam, porque ambas pedem pela ordem do id.
#   2. lock_location! — FOR SHARE no local (e na unidade, se `unit`).
#   3. o documento.
#
# `record!` PRESSUPÕE a trava do lote: quem chama trava antes e relê o saldo
# (balance/balances) já sob a trava.
module Pharmacy
  module Ledger
    NEGATIVE_BALANCE = /negative balance refused/

    # Saldo que ficaria negativo. Só o lote (id) fica na exceção: nada de
    # número de lote, quantidade ou paciente em mensagem de erro.
    class Insufficient < StandardError
      attr_reader :lot_id

      def initialize(lot_id = nil)
        @lot_id = lot_id
        super("insufficient balance")
      end
    end

    # Local (ou a unidade dele) inexistente ou desativado.
    class Inactive < StandardError; end

    DOCUMENTS = { StockEntry => :stock_entry, StockTransfer => :stock_transfer,
                  DispensationItem => :dispensation_item, StockAdjustment => :stock_adjustment }.freeze

    module_function

    # -> BigDecimal
    def balance(location_id:, lot_id:)
      StockMovement.where(stock_location_id: location_id, stock_lot_id: lot_id).sum(:quantity).to_d
    end

    # -> { lot_id => BigDecimal }; lote sem movimento no local = 0
    def balances(location_id:, lot_ids:)
      ids = Array(lot_ids).uniq
      sums = StockMovement.where(stock_location_id: location_id, stock_lot_id: ids).group(:stock_lot_id).sum(:quantity)
      ids.index_with { |id| (sums[id] || 0).to_d }
    end

    # Passo 1 da ordem de travas. -> { id => StockLot } (id inexistente fica de fora)
    def lock_lots!(lot_ids)
      ids = Array(lot_ids).compact.uniq.sort
      return {} if ids.empty?

      StockLot.where(id: ids).order(:id).lock("FOR UPDATE").index_by(&:id)
    end

    # Passo 2. FOR SHARE em local ativo; `unit` trava também a unidade ativa.
    # -> StockLocation; inativo ou inexistente → Inactive.
    def lock_location!(location_id)
      location = StockLocation.where(active: true).lock("FOR SHARE").find_by(id: location_id) || raise(Inactive)
      HealthUnit.lock_active!(location.health_unit_id) if location.unit?
      location
    rescue HealthUnit::Inactive
      raise Inactive
    end

    # Grava UM movimento. `quantity` positiva (BigDecimal ou Integer) para todo
    # tipo, exceto `adjustment`, que leva o sinal; o sinal gravado é o do tipo.
    # `document` é StockEntry | StockTransfer | DispensationItem |
    # StockAdjustment. Saldo que ficaria negativo → Insufficient, pela conta
    # daqui ou pelo trigger. Erro de programação (tipo, quantidade, documento)
    # → ArgumentError.
    def record!(location:, lot:, kind:, quantity:, by:, document:, reason: nil, package: nil, at: Time.current)
      signed = signed_quantity(kind, quantity)
      reference = DOCUMENTS.find { |model, _name| document.is_a?(model) }&.last or raise ArgumentError, "unknown ledger document"

      raise Insufficient, lot.id if balance(location_id: location.id, lot_id: lot.id) + signed < 0

      units = package&.to_h&.symbolize_keys
      # Savepoint: a recusa do trigger aborta a transação do Postgres; sem ele a
      # do chamador ficaria inutilizável (a dispensação junta todas as recusas).
      StockMovement.transaction(requires_new: true) do
        StockMovement.create!(stock_location: location, stock_lot: lot, catalog_item_id: lot.catalog_item_id, kind: kind, quantity: signed,
                              reference => document, reason: reason, recorded_by_user: by, recorded_at: at, created_at: at,
                              package_units: units&.fetch(:units_per_package), packages: units&.fetch(:packages))
      end
    rescue ActiveRecord::StatementInvalid => e
      raise unless e.message.match?(NEGATIVE_BALANCE)

      raise Insufficient, lot.id
    end

    def signed_quantity(kind, quantity)
      raise ArgumentError, "unknown movement kind" unless Catalog::MOVEMENT_KINDS.include?(kind)
      raise ArgumentError, "quantity must be a BigDecimal or an Integer" unless quantity.is_a?(BigDecimal) || quantity.is_a?(Integer)
      raise ArgumentError, "quantity has more than two decimals" unless quantity.round(2) == quantity

      if kind == "adjustment"
        raise ArgumentError, "adjustment quantity must not be zero" if quantity.zero?

        quantity.to_d
      else
        raise ArgumentError, "quantity must be positive" unless quantity.positive?

        Catalog::POSITIVE_KINDS.include?(kind) ? quantity.to_d : -quantity.to_d
      end
    end
    private_class_method :signed_quantity
  end
end
