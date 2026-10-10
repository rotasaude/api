# app/services/clinical_documents/uuid.rb
# Fonte única do formato de UUID do 19c (controllers, conteúdo e comandos):
# ids vindos do cliente são conferidos antes de ir ao banco (uuid inválido no
# PG levantaria StatementInvalid).
module ClinicalDocuments
  module Uuid
    PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def valid?(value) = value.is_a?(String) && value.match?(PATTERN)
  end
end
