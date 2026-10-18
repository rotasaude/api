# Bloqueio do CIQ na liberação do 21b (spec §5.4; ADR 0038 Invariantes):
# item cujo exame (versão) está ligado a um aparelho com bloqueio ativo de
# um analito da versão, sem exceção daquele bloqueio para o item, não sai.
# A trava FOR SHARE dos aparelhos vem ANTES da requisição (Desvio 10): a
# reprovação concorrente (FOR UPDATE no aparelho) espera ou é esperada.
module Lab
  module Qc
    module ReleaseCheck
      module_function

      def lock_instruments!(item_ids)
        ids = LabRequisitionItem.where(id: item_ids).joins(:lab_exam_version).where.not(lab_exam_versions: { lab_instrument_id: nil })
                                .distinct.pluck("lab_exam_versions.lab_instrument_id").sort
        LabInstrument.where(id: ids).order(:id).lock("FOR SHARE").to_a if ids.any?
      end

      # items com lab_exam_version carregada; chame depois de lock_instruments!.
      def blocked(items)
        pairs = items.filter_map { |item| [ item, item.lab_exam_version ] if item.lab_exam_version.lab_instrument_id }
        return [] if pairs.empty?

        blocks = LabQcBlock.active.includes(:lab_instrument).where(lab_instrument_id: pairs.map { |_, v| v.lab_instrument_id }.uniq).to_a
        return [] if blocks.empty?

        excepted = LabQcException.where(lab_qc_block_id: blocks.map(&:id), lab_requisition_item_id: items.map(&:id))
                                 .pluck(:lab_qc_block_id, :lab_requisition_item_id).to_set
        pairs.flat_map do |item, version|
          blocks.select { |b| b.lab_instrument_id == version.lab_instrument_id && version.analyte(b.analyte_key) && !excepted.include?([ b.id, item.id ]) }
                .map do |b|
                  { item_id: item.id, block_id: b.id, analyte_key: b.analyte_key, instrument_id: b.lab_instrument_id,
                    instrument_name: b.lab_instrument.name } # C9
                end
        end.sort_by { |h| [ h[:item_id], h[:analyte_key] ] }
      end
    end
  end
end
