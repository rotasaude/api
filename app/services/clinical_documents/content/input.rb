# app/services/clinical_documents/content/input.rb
# Leitura defensiva do `content` do contrato (§2): tipos exatos, textos
# aparados com limite, datas ISO. Nenhum valor vai a mensagem de erro — só o
# nome do campo.
module ClinicalDocuments
  module Content
    module Input
      module_function

      def object(value)
        value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
        value.is_a?(Hash) ? value.to_h.stringify_keys : {}
      end

      def invalid(field) = Result.fail(:invalid_content, details: { field: field })

      # nil quando ausente ou vazio; :invalid quando não é texto ou passa do limite.
      def text(value, range)
        return nil if value.nil?
        return :invalid unless value.is_a?(String)

        trimmed = value.gsub(/\r\n?/, "\n").strip
        return nil if trimmed.empty?

        range.cover?(trimmed.size) ? trimmed : :invalid
      end

      def date(value) = IsoDate.parse(value)
    end
  end
end
