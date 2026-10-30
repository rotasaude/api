# Devolução de medicamento dispensado (ADR 0045; plano do api, Desvio 12;
# contrato H9/H12): o paciente devolve, em condições de uso, parte de um item
# dispensado; volta ao MESMO lote, no local da dispensação, como movimento
# `return` positivo com o item dispensado como documento. Devolver abate o
# `dispensed_total` do item da receita (Pharmacy::Dispensed) e libera nova
# retirada.
#
# Recusas (todas de uma vez, H8/H12): quantidade (invalid_quantity `quantity`),
# motivo de 10 a 500 (invalid_reason `reason`), lote vencido (lot_expired
# `dispensation_item_id`: vencido não volta à prateleira) e mais que o
# dispensado menos o já devolvido (return_exceeds `quantity`, relido sob a
# trava). Quem pode (farmacêutico ou auxiliar do local da dispensação; item
# CONTROLADO só o farmacêutico, `controlled?`) é do controlador.
#
# Ordem de travas (a do módulo): lote → local → a dispensação (FOR UPDATE:
# duas devoluções do mesmo item se enfileiram). Evento `dispensation.returned`
# só com ids (dispensation_id, user_id); o motivo é cifrado no movimento e só
# sai no corpo (extrato), nunca em log, evento ou erro.
module Pharmacy
  module RecordReturn
    class Refused < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super("return refused")
      end
    end

    module_function

    # -> Result.ok(dispensation:, movement:) | fail(<primeiro erro>, details: { path:, problems: }) |
    # fail(:location_inactive, details: { path: })
    def call(location:, dispensation_item:, quantity:, reason:, by:, now: Time.current)
      raise ArgumentError, "return outside the dispensation location" unless dispensation_item.dispensation.stock_location_id == location.id

      problems = []
      amount = Quantity.parse(quantity)
      problems << problem("quantity", :invalid_quantity) unless amount
      text = reason.is_a?(String) ? reason.strip : nil
      problems << problem("reason", :invalid_reason) unless text && Catalog::REASON.cover?(text.length)
      lot = dispensation_item.stock_lot
      problems << problem("dispensation_item_id", :lot_expired) if lot.expired?(now.in_time_zone.to_date)
      problems << problem("quantity", :return_exceeds) if amount && exceeds?(dispensation_item, amount)
      return failure(problems) if problems.any?

      ApplicationRecord.transaction(requires_new: true) { write(location, dispensation_item, amount, text, by, now) }
    rescue Refused => e
      e.result
    end

    def write(location, dispensation_item, amount, text, by, now)
      lot = Ledger.lock_lots!([ dispensation_item.stock_lot_id ]).fetch(dispensation_item.stock_lot_id)
      Ledger.lock_location!(location.id)
      dispensation = Dispensation.lock.find(dispensation_item.dispensation_id)
      raise Refused, failure([ problem("quantity", :return_exceeds) ]) if exceeds?(dispensation_item, amount)

      movement = Ledger.record!(location: location, lot: lot, kind: "return", quantity: amount, by: by, document: dispensation_item, reason: text, at: now)
      DomainEvents.publish("dispensation.returned", dispensation_id: dispensation.id, user_id: by.id)
      Result.ok(dispensation: dispensation, movement: movement)
    rescue Ledger::Inactive
      raise Refused, Result.fail(:location_inactive, details: { path: "location_id" })
    end

    # Item dispensado CONTROLADO (ruling da revisão final), o critério da
    # dispensação: a retenção guardou o número (só há número com item
    # controlado), a receita do 19c é de controle especial, o retrato da lista
    # gravado no item da externa, ou o catálogo do item dispensado (o da
    # receita ou o escolhido para o texto livre) o marca `controlled`. Lê o
    # catálogo da plataforma: chamar FORA da transação.
    def controlled?(dispensation_item)
      dispensation = dispensation_item.dispensation
      return true if dispensation.retained && dispensation.notification_number.present?
      return true if dispensation_item.external_prescription_item&.controlled_list.present?
      return true if dispensation.clinical_document&.content_data&.dig("category") == "special_control"

      MedicationCatalogItem.find_by(id: dispensation_item.catalog_item_id)&.controlled == true
    end

    # Já devolvido + o pedido acima do dispensado.
    def exceeds?(dispensation_item, amount)
      returned = Dispensed.returned_totals([ dispensation_item.id ]).fetch(dispensation_item.id, BigDecimal("0"))
      returned + amount > dispensation_item.quantity
    end

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :write, :exceeds?, :problem, :failure
  end
end
