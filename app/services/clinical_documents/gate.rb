# Os documentos clínicos só são EMITIDOS com o interruptor clinical_documents
# LIGADO e UTILIZÁVEL (ADR 0033; requer clinical_record utilizável). Relido
# da plataforma a cada chamada. Leitura e conferência não dependem dele.
module ClinicalDocuments
  module Gate
    KEY = "clinical_documents".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
