# Dispensação pela receita (ADR 0045; plano do api, Task 11; contrato §7, H3,
# H6, H8, H12): sai do lote da farmácia da unidade o que a receita pede, um
# `dispensing` por linha, com o item da receita, o lote e a quantidade.
#
# `prescription` é o Pharmacy::Prescription lido FORA da transação (com o
# catálogo da plataforma); `catalog` = { catalog_item_id => MedicationCatalogItem }
# cobre os itens da receita e os `catalog_item_id` do corpo. `items` é a lista do
# corpo, chaves String: `{ prescription_item_id, catalog_item_id?, lot_id,
# quantity, complete? }`; `retention` é o objeto do corpo ou nil.
#
# Ordem das recusas:
#   1. receita cancelada (lida fora) → prescription_cancelled, sozinha, antes de
#      qualquer outra regra (Desvio 8);
#   2. `items` 1..20 → invalid_request `items`, sozinha;
#   3. 403 de papel, SOZINHO (H12): item em texto livre sem ser farmacêutico →
#      free_text_requires_pharmacist; item controlado (catálogo, ou o retrato da
#      lista na externa, ou o escolhido para o texto livre) →
#      controlled_requires_pharmacist;
#   4. todas as demais de uma vez (H8/H12): `error`/`path` da primeira e
#      `problems: [ { path, error, next_allowed_on? } ]`, por linha e depois a
#      retenção. Por linha: `prescription_item_id` da receita (invalid_item),
#      texto livre sem `catalog_item_id` do catálogo ativo e `catalog_item_id`
#      diferente do item da receita (invalid_item `items[i].catalog_item_id`),
#      lote que não existe ou de outro item (invalid_item `items[i].lot_id`),
#      lote vencido (lot_expired `items[i].lot_id`), quantidade
#      (invalid_quantity), `complete` não booleano; item vencido
#      (prescription_expired `items[i]`), completo (item_completed `items[i]`),
#      cedo demais no uso contínuo (too_early `items[i]`, `next_allowed_on`) e
#      saldo pela SOMA por lote (insufficient_balance no path da linha que
#      estoura; Desvio 11). Retenção: `retention_required` (H6/H12) = catálogo
#      antimicrobiano OU controlado OU conteúdo de controle especial do 19c,
#      recalculado para o texto livre pelo catálogo escolhido; sem `retention` →
#      retention_required; número do corpo diferente do documento →
#      invalid_request `retention.notification_number`.
#
# Quando há recusa antes da trava, as recusas de estado (vencido, completo,
# cedo, saldo) são apuradas sem trava só para virem juntas; o veredito da
# escrita é o relido SOB as travas.
#
# Ordem de travas (a do módulo, Pharmacy::Ledger): lotes → local → documento.
#   1. lock_lots! — FOR UPDATE em TODOS os lotes, em ordem de id, ANTES de
#      inserir dispensation_items e movimentos (o FK pede FOR KEY SHARE no lote);
#   2. lock_location! (FOR SHARE no local e na unidade) → location_inactive;
#   3. o documento: ClinicalDocument FOR UPDATE (o mesmo do ClinicalDocuments::
#      Cancel, que espera) ou ExternalPrescription FOR UPDATE; sob ela, a
#      cancelada relida, o Dispensed.summary relido e o saldo relido.
#
# Retenção gravada: `retained` e, só com item CONTROLADO, o número do
# documento (`sncr.number` da digital, `notification_number` da externa);
# antimicrobiano não controlado grava `notification_number: null` (H12).
#
# Evento `dispensation.recorded` só com ids (dispensation_id, user_id). Nada do
# paciente, do medicamento nem do número em Result, evento, erro ou inspect.
module Pharmacy
  module Dispense
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # Linha validada. Medicamento e quantidade: nada em inspect, to_s,
    # pretty_print nem as_json.
    Row = Data.define(:index, :item, :entry, :lot, :quantity, :complete, :mapped) do
      def inspect = "#<Pharmacy::Dispense::Row #{index}>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "index" => index }
    end

    # O que a linha diz, mesmo inválida: o item da receita e o do catálogo
    # pesam no papel e na retenção.
    Line = Data.define(:index, :item, :entry, :row, :problems) do
      def inspect = "#<Pharmacy::Dispense::Line #{index}>"
      def to_s = inspect
      def pretty_print(pp) = pp.text(inspect)
      def as_json(*) = { "index" => index }
    end

    class Refused < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super("dispensation refused")
      end
    end

    module_function

    # -> Result.ok(dispensation:) | fail(:prescription_cancelled | <primeiro erro>, details: { path:, problems: }) |
    # fail(:free_text_requires_pharmacist | :controlled_requires_pharmacist) | fail(:location_inactive, details: { path: })
    def call(location:, prescription:, items:, retention:, by:, role:, catalog:, settings:, now: Time.current)
      raise ArgumentError, "unknown dispenser role" unless Catalog::DISPENSER_ROLES.include?(role)

      today = now.in_time_zone.to_date
      return cancelled if prescription.cancelled
      return failure([ problem("items", :invalid_request) ]) unless items.is_a?(Array) && items.size.between?(1, Catalog::MAX_DISPENSE_ITEMS)

      lines = parse_lines(items, prescription, catalog, today)
      pharmacist = role == "pharmacist"
      return Result.fail(:free_text_requires_pharmacist) if !pharmacist && lines.any? { |line| line.item&.catalog_item_id.nil? && line.item }
      return Result.fail(:controlled_requires_pharmacist) if !pharmacist && lines.any? { |line| controlled?(line) }

      retained, number, retention_problems = parse_retention(retention, lines, prescription)
      problems = lines.flat_map(&:problems)
      rows = lines.filter_map(&:row)
      if problems.any? || retention_problems.any?
        balances = Ledger.balances(location_id: location.id, lot_ids: rows.map { |row| row.lot.id })
        state = state_problems(rows, Dispensed.summary(prescription), balances, today, settings)
        return failure(by_line(problems + state, items.size) + retention_problems)
      end

      persist(location: location, prescription: prescription, rows: rows, retained: retained, number: number, by: by, role: role,
              settings: settings, now: now, today: today)
    end

    # ---- validação (sem trava) ---------------------------------------------

    def parse_lines(items, prescription, catalog, today)
      lot_ids = items.filter_map { |raw| raw["lot_id"] if raw.is_a?(Hash) && raw["lot_id"].is_a?(String) && raw["lot_id"].match?(UUID) }
      lots = StockLot.where(id: lot_ids.uniq).index_by(&:id)
      by_id = prescription.items.index_by(&:id)
      items.each_with_index.map do |raw, index|
        next Line.new(index: index, item: nil, entry: nil, row: nil, problems: [ problem("items[#{index}]", :invalid_request) ]) unless raw.is_a?(Hash)

        parse_line(raw, index, by_id, catalog, lots, today)
      end
    end

    def parse_line(raw, index, by_id, catalog, lots, today)
      prefix = "items[#{index}]"
      problems = []
      item = raw["prescription_item_id"].is_a?(String) ? by_id[raw["prescription_item_id"]] : nil
      problems << problem("#{prefix}.prescription_item_id", :invalid_item) unless item

      entry, mapped, found = catalog_entry(raw, item, catalog, prefix)
      problems.concat(found)

      lot = raw["lot_id"].is_a?(String) ? lots[raw["lot_id"]] : nil
      wanted = item && (mapped ? entry&.id : item.catalog_item_id)
      if lot.nil? || (wanted && lot.catalog_item_id != wanted)
        problems << problem("#{prefix}.lot_id", :invalid_item)
        lot = nil
      elsif lot.expired?(today)
        # O dia da validade ainda vale; o lote imutável não precisa de trava.
        problems << problem("#{prefix}.lot_id", :lot_expired)
      end

      quantity = Quantity.parse(raw["quantity"])
      problems << problem("#{prefix}.quantity", :invalid_quantity) unless quantity

      complete = raw.fetch("complete", false)
      problems << problem("#{prefix}.complete", :invalid_request) unless [ true, false ].include?(complete)

      row = problems.empty? ? Row.new(index: index, item: item, entry: entry, lot: lot, quantity: quantity, complete: complete, mapped: mapped) : nil
      Line.new(index: index, item: item, entry: entry, row: row, problems: problems)
    end

    # -> [ MedicationCatalogItem | nil, mapped (bool), [ problem ] ]. Texto livre:
    # o farmacêutico escolhe um item ATIVO do catálogo. Item do catálogo: o corpo
    # pode repetir o id, nunca trocar.
    def catalog_entry(raw, item, catalog, prefix)
      return [ nil, false, [] ] unless item

      chosen = raw["catalog_item_id"]
      if item.catalog_item_id.nil?
        entry = chosen.is_a?(String) ? catalog[chosen] : nil
        entry = nil unless entry&.status == "active"
        return [ entry, true, entry ? [] : [ problem("#{prefix}.catalog_item_id", :invalid_item) ] ]
      end

      problems = !chosen.nil? && chosen != item.catalog_item_id ? [ problem("#{prefix}.catalog_item_id", :invalid_item) ] : []
      [ catalog[item.catalog_item_id], false, problems ]
    end

    # Controlado: o catálogo (digital), o retrato da lista (externa) ou o item
    # escolhido para o texto livre.
    def controlled?(line) = line.item.present? && (line.item.controlled || line.entry&.controlled == true)

    # H6/H12, recalculado para o texto livre pelo catálogo escolhido.
    def retention_required?(line)
      line.item.present? && (line.item.retention_required || line.entry&.antimicrobial == true || line.entry&.controlled == true)
    end

    # -> [ retained, notification_number | nil, [ problem ] ]. O número retido é o
    # do DOCUMENTO; o corpo não o substitui (divergente → invalid_request).
    def parse_retention(retention, lines, prescription)
      required = lines.any? { |line| retention_required?(line) }
      return [ false, nil, required ? [ problem("retention", :retention_required) ] : [] ] if retention.nil?
      return [ false, nil, [ problem("retention", :invalid_request) ] ] unless retention.is_a?(Hash)

      document = prescription.kind == "digital" ? prescription.sncr_number : prescription.record.notification_number
      given = retention["notification_number"]
      return [ false, nil, [ problem("retention.notification_number", :invalid_request) ] ] if !given.nil? && given != document

      [ true, lines.any? { |line| controlled?(line) } ? document : nil, [] ]
    end

    # Recusas de estado, na ordem das linhas: vencido, completo, cedo demais e o
    # saldo pela soma por lote (a linha que estoura e as seguintes do mesmo lote).
    def state_problems(rows, summary, balances, today, settings)
      used = Hash.new(BigDecimal("0"))
      rows.flat_map do |row|
        prefix = "items[#{row.index}]"
        done = summary.fetch(row.item.id)
        found = []
        found << problem(prefix, :prescription_expired) if Validity.expired?(row.item.valid_until, today: today)
        found << problem(prefix, :item_completed) if done[:completed]
        next_allowed = row.item.continuous && done[:last_on] ? done[:last_on] + settings.continuous_interval_days : nil
        found << problem(prefix, :too_early).merge(next_allowed_on: next_allowed.iso8601) if next_allowed && today < next_allowed
        used[row.lot.id] += row.quantity
        found << problem("#{prefix}.quantity", :insufficient_balance) if used[row.lot.id] > balances.fetch(row.lot.id, BigDecimal("0"))
        found
      end
    end

    # Recusas das linhas na ordem das linhas (estáveis dentro da linha).
    def by_line(problems, size)
      problems.uniq.each_with_index.sort_by do |found, position|
        index = found[:path][/\Aitems\[(\d+)\]/, 1]
        [ index ? index.to_i : size, position ]
      end.map(&:first)
    end

    # ---- gravação (sob as travas) ------------------------------------------

    def persist(**args)
      Dispensation.transaction(requires_new: true) { write(**args) }
    rescue Refused => e
      e.result
    end

    def write(location:, prescription:, rows:, retained:, number:, by:, role:, settings:, now:, today:)
      lots = Ledger.lock_lots!(rows.map { |row| row.lot.id })
      Ledger.lock_location!(location.id)
      record = lock_document(prescription)
      refuse!(cancelled) if prescription.kind == "digital" && record.cancelled?

      balances = Ledger.balances(location_id: location.id, lot_ids: lots.keys)
      state = state_problems(rows, Dispensed.summary(prescription), balances, today, settings)
      refuse!(failure(state)) if state.any?

      dispensation = Dispensation.create!(stock_location: location, patient_id: prescription.patient_id, dispensed_by_user: by, dispensed_by_role: role,
                                          dispensed_at: now, retained: retained, notification_number: number,
                                          **(prescription.kind == "digital" ? { clinical_document_id: record.id } : { external_prescription_id: record.id }))
      rows.each do |row|
        lot = lots.fetch(row.lot.id)
        source = prescription.kind == "digital" ? { prescription_item_id: row.item.id } : { external_prescription_item_id: row.item.id }
        item = DispensationItem.create!(dispensation: dispensation, catalog_item_id: lot.catalog_item_id, stock_lot: lot, quantity: row.quantity,
                                        completes_item: row.complete, mapped_from_free_text: row.mapped, **source)
        Ledger.record!(location: location, lot: lot, kind: "dispensing", quantity: row.quantity, by: by, document: item, at: now)
      end
      DomainEvents.publish("dispensation.recorded", dispensation_id: dispensation.id, user_id: by.id)
      Result.ok(dispensation: dispensation)
    rescue Ledger::Inactive
      refuse!(Result.fail(:location_inactive, details: { path: "location_id" }))
    rescue Ledger::Insufficient => e
      # O trigger do banco, o cinto: só com o livro fora da trava.
      row = rows.find { |candidate| candidate.lot.id == e.lot_id } or raise KeyError, "insufficient balance on a lot outside the dispensation"
      refuse!(failure([ problem("items[#{row.index}].quantity", :insufficient_balance) ]))
    end

    # Passo 3: o documento, com a mesma trava do cancelamento do 19c.
    def lock_document(prescription)
      model = prescription.kind == "digital" ? ClinicalDocument : ExternalPrescription
      model.lock.find(prescription.id)
    end

    # Desfaz a transação inteira e devolve a recusa.
    def refuse!(result) = raise(Refused, result)

    # ---- resultado ---------------------------------------------------------

    def cancelled = failure([ problem("prescription", :prescription_cancelled) ])

    def problem(path, error) = { path: path, error: error.to_s }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], next_allowed_on: first[:next_allowed_on], problems: problems }.compact)
    end

    private_class_method :parse_lines, :parse_line, :catalog_entry, :controlled?, :retention_required?, :parse_retention, :state_problems,
                         :by_line, :persist, :write, :lock_document, :refuse!, :cancelled, :problem, :failure
  end
end
