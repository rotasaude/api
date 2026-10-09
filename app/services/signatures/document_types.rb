# app/services/signatures/document_types.rb
# Documentos assináveis (ADR 0032; aberto ao 19c). No banco, o nome do modelo;
# na API e nos eventos, o nome do contrato.
module Signatures
  module DocumentTypes
    MODELS = { "Consultation" => "consultation", "ConsultationAddendum" => "consultation_addendum" }.freeze

    module_function

    def api(db_type) = MODELS.fetch(db_type)

    def db(document)
      name = document.class.name
      raise ArgumentError, "documento fora do catálogo: #{name}" unless MODELS.key?(name)

      name
    end

    def find(db_type, id)
      return nil unless MODELS.key?(db_type)

      db_type.constantize.find_by(id: id)
    end

    def consultation_id(document) = document.is_a?(Consultation) ? document.id : document.consultation_id
  end
end
