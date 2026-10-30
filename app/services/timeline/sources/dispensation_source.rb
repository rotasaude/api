# Dispensação de medicamentos (ADR 0045; contrato H7): uma entrada por
# dispensação (dispensations.dispensed_at), SÓ para o profissional (o cidadão
# nunca a vê: Query::PROFESSIONAL_ONLY_KINDS). Mostra data, unidade e os
# medicamentos pelo rótulo do catálogo; nunca lote nem quantidade. Sem detalhe
# (`detail_ref: null`): a tela de retiradas é da farmácia, com as regras dela.
#
# NÃO consulta o interruptor `pharmacy` (Desvio 14): a dispensação é registro
# clínico retido e continua na linha do tempo com a farmácia desligada. Vazia
# sem paciente. Devolução não apaga a entrada: a retirada aconteceu. A trilha
# é do controlador (uma por leitura); nada daqui vai a log nem a evento.
module Timeline
  module Sources
    module DispensationSource
      KIND = "dispensation".freeze
      STATUS = "dispensed".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:)
        return [] unless person.patient_id

        scope = ::Dispensation.where(patient_id: person.patient_id)
                              .includes(:items, stock_location: :health_unit, dispensed_by_user: :professional)
        rows = Window.apply(scope, kind: KIND, column: "dispensations.dispensed_at", id_column: "dispensations.id",
                                   before: before, from: from, to: to).limit(limit).to_a
        # O catálogo da plataforma, de uma vez para a página.
        catalog = ::MedicationCatalogItem.where(id: rows.flat_map { |row| row.items.map(&:catalog_item_id) }.uniq).index_by(&:id)
        rows.map { |dispensation| entry(dispensation, catalog) }
      end

      def entry(dispensation, catalog)
        Entry.new(kind: KIND, source_id: dispensation.id, occurred_at: dispensation.dispensed_at, unit: unit(dispensation.stock_location),
                  professional: { name: Labels.professional_name(dispensation.dispensed_by_user), cbo_code: nil },
                  title: Labels::DISPENSATION_TITLE, summary: summary(dispensation, catalog), status: STATUS, detail_ref: nil, citizen: nil, document: nil)
      end
      private_class_method :entry

      # Rótulos distintos na ordem em que os itens foram gravados.
      def summary(dispensation, catalog)
        dispensation.items.sort_by { |row| [ row.created_at, row.id ] }
                    .filter_map { |row| catalog[row.catalog_item_id]&.label }.uniq.join("; ")
      end
      private_class_method :summary

      def unit(location)
        place = location.health_unit
        place ? { id: place.id, name: place.name } : { id: location.id, name: location.name }
      end
      private_class_method :unit
    end
  end
end
