# Complemento dos dados BNAFAR de um lote já gravado (módulo 27b, Task 5;
# contrato §2; Q7, Q16, Q21): `PATCH /pharmacy/lots/:id/bnafar`.
#
# `attrs` (chaves String) traz só os campos BNAFAR (LotFields.keys_for; chave
# desconhecida é `invalid_request` com a chave no path). Campo nulo vira valor,
# o preço troca, o preenchido diferente é `lot_mismatch` (path = o campo).
# Na vacina o CNPJ não é digitado (Q21): `manufacturer_cnpj` é recusado.
# `manufacturer` só vale junto de `manufacturer_international: true` (Q15).
#
# `expected_version` é a `bnafar_version` do lote: diferente sob a trava →
# `lot_bnafar_changed`. Um UPDATE só, com bnafar_version + 1 (o guard do banco
# exige), sob a trava do lote (Pharmacy::Ledger.lock_lots!); sem mudança, sem
# UPDATE e sem evento. Evento `stock_lot.bnafar_completed` só com ids.
module Bnafar
  module CompleteLot
    module_function

    # -> Result.ok(lot:) | fail(:invalid_request | :program_unknown | :ampp_unknown | … | :lot_mismatch | :lot_bnafar_changed,
    #                          details: { path:, problems: })
    def call(lot:, attrs:, expected_version:, by:)
      return refuse([ problem("attrs", :invalid_request) ]) unless attrs.is_a?(Hash)
      return refuse([ problem("expected_version", :expected_version_required) ]) unless expected_version.is_a?(Integer)

      domain = Stock::Domain.of_lot(lot)
      attrs = attrs.transform_keys(&:to_s)
      problems = shape_problems(attrs, domain)
      fields, parse_problems = LotFields.parse(attrs, prefix: "", stock_domain: domain, required: false, vmp_code: vmp_of(lot, domain),
                                                      current_anvisa: lot.anvisa_registration)
      problems += parse_problems
      return refuse(problems) if problems.any?

      lot.class.transaction(requires_new: true) do
        locked = Pharmacy::Ledger.lock_lots!([ lot.id ]).fetch(lot.id)
        next Result.fail(:lot_bnafar_changed) if locked.bnafar_version != expected_version

        changes, conflicts = LotFields.diff(locked, fields)
        next refuse(conflicts.map { |field| problem(field.to_s, :lot_mismatch) }) if conflicts.any?
        next Result.ok(lot: locked) if changes.empty?

        locked.update!(changes.merge(bnafar_version: locked.bnafar_version + 1))
        DomainEvents.publish("stock_lot.bnafar_completed", stock_lot_id: locked.id, user_id: by.id)
        Result.ok(lot: locked)
      end
    end

    # Chaves fora do domínio e `manufacturer` sem o internacional.
    def shape_problems(attrs, domain)
      allowed = LotFields.keys_for(domain)
      problems = (attrs.keys - allowed).map { |key| problem(key.to_s[0, 64], :invalid_request) }
      if attrs.key?("manufacturer") && !attrs["manufacturer"].nil? && attrs["manufacturer_international"] != true && allowed.include?("manufacturer")
        problems << problem("manufacturer", :invalid_request)
      end
      problems.uniq
    end

    def vmp_of(lot, domain)
      case domain
      when Stock::Domain::IMMUNOBIOLOGICAL then Vaccination::Immunobiologicals.find(lot.immunobiological_code)&.obm_vmp
      when Stock::Domain::VECTOR_CONTROL then nil
      else MedicationCatalogItem.where(id: lot.catalog_item_id).pick(:vmp_code)
      end
    end

    def problem(path, error) = { path: path, error: error.to_s }

    def refuse(problems)
      first = problems.first
      Result.fail(first[:error], details: { path: first[:path], problems: problems })
    end

    private_class_method :shape_problems, :vmp_of, :problem, :refuse
  end
end
