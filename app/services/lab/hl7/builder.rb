# Respostas ER7 (perfil rotasaude.lab.hl7.v1; Divergência D1): ACK^R22^ACK e
# RSP^K11^RSP_K11; ERR-3 = tabela HL7 0357, ERR-4 = severidade, ERR-5 = nosso
# código (99RSL). Um ERR por recusa (B22). Nunca dado do paciente: o RSP só leva
# amostra, material e exames.
module Lab
  module Hl7
    module Builder
      Error = Data.define(:code, :location)
      ERRORS = {
        "unknown_barcode" => [ "204", "Unknown key identifier", "Codigo de barras desconhecido" ],
        "sample_not_received" => [ "207", "Application internal error", "Amostra nao recebida" ],
        "exam_not_in_version" => [ "204", "Unknown key identifier", "Exame fora da versao" ],
        "unknown_analyte" => [ "204", "Unknown key identifier", "Componente desconhecido" ],
        "out_of_entry_range" => [ "207", "Application internal error", "Valor fora da faixa de digitacao" ],
        "unit_mismatch" => [ "207", "Application internal error", "Unidade diferente" ],
        "invalid_value" => [ "102", "Data type error", "Valor invalido" ],
        "invalid_message" => [ "100", "Segment sequence error", "Mensagem invalida" ],
        "unsupported_message_type" => [ "200", "Unsupported message type", "Tipo de mensagem nao suportado" ],
        "unsupported_version" => [ "203", "Unsupported version id", "Versao nao suportada" ],
        "token_revoked" => [ "207", "Application internal error", "Token revogado" ],
        "feature_disabled" => [ "207", "Application internal error", "Entrada desligada" ]
      }.freeze
      GENERIC_ERROR = [ "207", "Application internal error", "Erro da aplicacao" ].freeze
      QUERY_NAME = "LabWorklist^Lista de trabalho^99RSL".freeze

      module_function

      def escape(text)
        # O perfil só admite os 5 escapes: CR/LF e demais controles viram espaço (nunca segmento novo).
        text.to_s.gsub(/[\x00-\x1F\x7F]+/, " ").gsub("\\") { "\\E\\" }.gsub("|") { "\\F\\" }.gsub("^") { "\\S\\" }
            .gsub("&") { "\\T\\" }.gsub("~") { "\\R\\" }
      end

      # B28: sem acento, minúsculo, não alfanumérico → "_", sem "_" nas pontas.
      def material_key(material)
        I18n.transliterate(material.to_s).downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      end

      def ack(request:, code:, city_slug:, now:, errors: [])
        render([ msh(request, "ACK^R22^ACK", city_slug, now), msa(request, code), *errors.map { |e| err(e) } ])
      end

      def rsp(request:, code:, city_slug:, query_tag:, barcode:, now:, sample: nil, items: [], errors: [])
        lines = [ msh(request, "RSP^K11^RSP_K11", city_slug, now), msa(request, code), *errors.map { |e| err(e) } ]
        with_group = sample && items.any? && errors.empty?
        status = errors.any? ? "AE" : (with_group ? "OK" : "NF")
        lines << [ "QAK", escape(query_tag), status, QUERY_NAME ]
        lines << [ "QPD", QUERY_NAME, escape(query_tag), escape(barcode) ]
        if with_group
          lines << [ "SPM", "1", escape(sample.barcode), "",
                     "#{material_key(sample.material)}^#{escape(sample.material)}^99RSL", *Array.new(12, ""),
                     sample.collected_at&.in_time_zone&.strftime("%Y%m%d%H%M%S").to_s ]
          items.each_with_index do |item, i|
            version = item.lab_exam_version
            lines << [ "ORC", "NW", item.id ]
            lines << [ "OBR", (i + 1).to_s, item.id, "", "#{escape(version.instrument_test_code)}^#{escape(version.lab_exam.name)}^99RSL" ]
          end
        end
        render(lines)
      end

      def msh(request, type, city_slug, now)
        [ "MSH", "^~\\&", "ROTA-SAUDE", escape(city_slug), request&.raw_msh(3).to_s, request&.raw_msh(4).to_s,
          now.in_time_zone.strftime("%Y%m%d%H%M%S"), "", type, SecureRandom.hex(10), request&.processing_id || "P", "2.5.1" ]
      end

      def msa(request, code) = [ "MSA", code, escape(request&.control_id) ]

      def err(error)
        hl7, name, text = ERRORS[error.code]
        unless hl7
          # Nunca levanta no meio de uma resposta; só o nome do código vai ao log.
          Rails.logger.error("lab.hl7.unknown_error_code=#{error.code.to_s[/\A[a-z0-9_]{1,40}\z/] || 'invalid'}")
          hl7, name, text = GENERIC_ERROR
        end
        [ "ERR", "", error.location.to_s, "#{hl7}^#{name}^HL70357", "E", "#{ERRORS.key?(error.code) ? error.code : 'application_error'}^#{text}^99RSL" ]
      end

      def render(lines) = lines.map { |fields| fields.join("|") }.join("\r") + "\r"
      private_class_method :msh, :msa, :err, :render
    end
  end
end
