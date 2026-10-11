# app/services/clinical_documents/canonical.rb
# O `content` do JSON canônico do documento clínico (ADR 0033; esquema
# clinical-document-v1 da tag clinical-v1.1.0; contrato §12): a forma do
# contrato §2, a mesma gravada no documento. Só normaliza o que o esquema fixa:
# `note` sempre presente (null quando vazio) no atestado e na requisição; o
# acompanhante nunca leva `days`; o código CID-10 com a normalização da entrada
# (ClinicalTerms.normalize; o esquema não tem pattern); na receita,
# `catalog_release` sempre presente (o uuid da release, ou null se só texto
# livre) e opcional ausente quando não se aplica; `catalog_item` vai inteiro,
# com `dosage_form: null` quando o CATMAT não traz a forma (decisão do usuário,
# 2026-10-10: assina normalmente). Desde clinical-v1.2.0 (ADR 0034; contrato
# §12): a receita comum sai sem `category` (a forma da 1.1.0, byte a byte); as
# chaves nulas (`sncr`, `patient_identification`, `prescriber_contact`,
# `complement` dos endereços) ficam ausentes, nunca null; `paper_reason` e as
# marcas `controlled_list`/`anticonvulsant` do item do catálogo nunca entram.
# O que o esquema não aceita faz o construtor
# levantar Invalid — o pedido fica pendente com verification_failed, nunca
# assina fora do esquema.
module ClinicalDocuments
  module Canonical
    module_function

    def content(document)
      data = document.content_data
      case document.kind
      when "sick_note" then sick_note(data)
      when "exam_requisition"
        exams = Array(data["exams"]).map { |exam| cid(exam.compact, "cid10_justification") }
        data.except("exams", "note").compact.merge("exams" => exams, "note" => data["note"].presence)
      when "attendance_declaration" then data.compact
      when "prescription" then prescription(data)
      end
    end

    def sick_note(data)
      result = data.except("note").compact
      result = result.except("days") if result["type"] == "companion"
      result = result.merge("cid10" => cid(result["cid10"], "code")) if result["cid10"]
      result.merge("note" => data["note"].presence)
    end

    CATALOG_MARKS = %w[controlled_list anticonvulsant].freeze

    def prescription(data)
      items = data["items"].map do |item|
        item = item.compact # só o nível do item: catalog_item.dosage_form pode ser null
        item["catalog_item"] ? item.merge("catalog_item" => item["catalog_item"].except(*CATALOG_MARKS)) : item
      end
      result = data.except("items", "catalog_release", "paper_reason").compact
      result.delete("category") if result["category"] == "common"
      %w[patient_identification prescriber_contact].each do |key|
        result[key] = result[key].merge("address" => result[key]["address"].compact) if result[key].is_a?(Hash) && result[key]["address"].is_a?(Hash)
      end
      result.merge("items" => items, "catalog_release" => data["catalog_release"])
    end

    def cid(hash, key) = hash[key].nil? ? hash : hash.merge(key => ClinicalTerms.normalize(hash[key]))
    private_class_method :sick_note, :prescription, :cid
  end
end
