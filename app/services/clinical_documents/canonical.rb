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
# 2026-10-10: assina normalmente). O que o esquema não aceita faz o construtor
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
      when "prescription"
        items = data["items"].map(&:compact) # só o nível do item: catalog_item.dosage_form pode ser null
        data.except("items", "catalog_release").compact.merge("items" => items, "catalog_release" => data["catalog_release"])
      end
    end

    def sick_note(data)
      result = data.except("note").compact
      result = result.except("days") if result["type"] == "companion"
      result = result.merge("cid10" => cid(result["cid10"], "code")) if result["cid10"]
      result.merge("note" => data["note"].presence)
    end

    def cid(hash, key) = hash[key].nil? ? hash : hash.merge(key => ClinicalTerms.normalize(hash[key]))
    private_class_method :sick_note, :cid
  end
end
