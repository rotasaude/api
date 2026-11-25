# Desfazer da importação aplicada (módulo 27b; contrato §5; Q10, Q24; R22).
#
# Bloqueado (`revert_blocked`, `details: { path: "id", locations: [id] }`)
# quando um local da importação tem movimento criado no `applied_at` ou
# depois, fora os da própria importação, ou qualquer `bnafar_records` criado
# no `applied_at` ou depois, enviado ou não (a remessa montada e ainda
# `queued` também: a BNAFAR receberia a posição com a abertura desfeita). A
# comparação é pelo `created_at`; o movimento de antes do apply não bloqueia.
#
# Numa transação só: trava a importação, os lotes (FOR UPDATE, em ordem de
# id) e então confere o bloqueio; grava um `opening_reversal` por movimento de
# abertura (a mesma quantidade, documentado pela entrada de abertura), marca
# `stock_openings.reverted_at` (libera a reabertura), `reverted` com version
# + 1 e o evento `opening_import.reverted` só com ids.
module OpeningImports
  module Revert
    class Blocked < StandardError; end

    module_function

    # -> Result.ok(import:) | fail(:expected_version_required | :opening_import_changed | :revert_blocked)
    def call(import:, expected_version:, by:, now: Time.current)
      return Changes.version_required unless expected_version.is_a?(Integer)

      OpeningImport.transaction do
        locked = OpeningImport.lock.find(import.id)
        next Changes.changed unless locked.status == "applied" && locked.version == expected_version

        entry_ids = OpeningImportRow.where(opening_import_id: locked.id).where.not(stock_entry_id: nil).distinct.pluck(:stock_entry_id)
        movements = StockMovement.where(stock_entry_id: entry_ids, kind: "opening").includes(:stock_location).order(:id).to_a
        lots = Pharmacy::Ledger.lock_lots!(movements.map(&:stock_lot_id))
        blocked = blocked_locations(movements.map(&:stock_location_id).uniq, entry_ids, locked.applied_at)
        next blocked_result(blocked) if blocked.any?

        movements.each do |movement|
          Pharmacy::Ledger.record!(location: movement.stock_location, lot: lots.fetch(movement.stock_lot_id), kind: "opening_reversal",
                                   quantity: movement.quantity.abs, by: by, document: movement.stock_entry, at: now,
                                   package: package_of(movement))
        end
        StockOpening.where(stock_entry_id: entry_ids, reverted_at: nil).update_all(reverted_at: now) # rubocop:disable Rails/SkipsModelValidations
        locked.update!(status: "reverted", reverted_at: now, version: locked.version + 1)
        DomainEvents.publish("opening_import.reverted", opening_import_id: locked.id, user_id: by.id)
        Result.ok(import: locked)
      rescue Pharmacy::Ledger::Insufficient => e
        # O cinto: o saldo do lote já não cobre a abertura. A exceção volta a
        # transação inteira (nenhum opening_reversal fica).
        raise Blocked, movements.find { |movement| movement.stock_lot_id == e.lot_id }&.stock_location_id.to_s
      end
    rescue Blocked => e
      blocked_result([ e.message ].reject(&:blank?))
    end

    # Locais com movimento (fora os da importação) ou registro BNAFAR criado no `applied_at` ou depois.
    def blocked_locations(location_ids, entry_ids, applied_at)
      moved = StockMovement.where(stock_location_id: location_ids).where(created_at: applied_at..)
                           .where("stock_entry_id IS NULL OR stock_entry_id NOT IN (?)", entry_ids.presence || [ nil ])
                           .distinct.pluck(:stock_location_id)
      recorded = BnafarRecord.where(stock_location_id: location_ids).where(created_at: applied_at..).distinct.pluck(:stock_location_id)
      (moved + recorded).uniq.sort
    end

    def blocked_result(locations) = Result.fail(:revert_blocked, details: { path: "id", locations: locations })

    def package_of(movement)
      return nil unless movement.package_units

      { units_per_package: movement.package_units, packages: movement.packages }
    end

    private_class_method :blocked_locations, :blocked_result, :package_of
  end
end
