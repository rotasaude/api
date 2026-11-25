# O item de um lote no envio à BNAFAR (módulo 27b; Q15, Q16, Q21): a chave
# (domínio e item), o rótulo e os códigos do produto. Lê de uma vez o catálogo
# de medicamentos da plataforma dos lotes dados; vacina pelo YAML; produto
# vetorial pelo `vector_product` do lote. Sem escrita e sem pessoa.
module Bnafar
  class Items
    def initialize(lots)
      ids = lots.filter_map(&:catalog_item_id).uniq
      @catalog = ids.empty? ? {} : MedicationCatalogItem.where(id: ids).index_by(&:id)
    end

    # "medication:<catalog_item_id>" | "immunobiological:<código>" | "vector_control:<vector_product_id>"
    def key(lot)
      case Stock::Domain.of_lot(lot)
      when Stock::Domain::IMMUNOBIOLOGICAL then "#{Stock::Domain::IMMUNOBIOLOGICAL}:#{lot.immunobiological_code}"
      when Stock::Domain::VECTOR_CONTROL then "#{Stock::Domain::VECTOR_CONTROL}:#{lot.vector_product_id}"
      else "#{Stock::Domain::MEDICATION}:#{lot.catalog_item_id}"
      end
    end

    def label(lot)
      case Stock::Domain.of_lot(lot)
      when Stock::Domain::IMMUNOBIOLOGICAL then vaccine(lot)&.name || lot.immunobiological_code
      when Stock::Domain::VECTOR_CONTROL then lot.vector_product.name
      else @catalog[lot.catalog_item_id]&.label || lot.catmat_code.to_s
      end
    end

    # VMP do OBM: o do catálogo (medicamento), o do YAML (vacina); o vetorial não tem.
    def vmp(lot)
      case Stock::Domain.of_lot(lot)
      when Stock::Domain::IMMUNOBIOLOGICAL then vaccine(lot)&.obm_vmp
      when Stock::Domain::VECTOR_CONTROL then nil
      else @catalog[lot.catalog_item_id]&.vmp_code
      end
    end

    # CATMAT (medicamento e vetorial) ou nil.
    def catmat(lot)
      case Stock::Domain.of_lot(lot)
      when Stock::Domain::IMMUNOBIOLOGICAL then nil
      when Stock::Domain::VECTOR_CONTROL then lot.vector_product.catmat_code
      else lot.catmat_code
      end
    end

    # O campo do código que falta ao produto (pendência `product_without_code`), ou nil.
    def missing_code(lot)
      case Stock::Domain.of_lot(lot)
      when Stock::Domain::IMMUNOBIOLOGICAL then "obm_vmp" if vmp(lot).blank?
      when Stock::Domain::VECTOR_CONTROL then "catmat_code" if catmat(lot).nil?
      else "vmp_code" if vmp(lot).blank?
      end
    end

    def vaccine(lot) = Vaccination::Immunobiologicals.find(lot.immunobiological_code)
  end
end
