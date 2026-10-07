# api#43 (ADR 0030; spec §6): o que a fila guarda de um erro do PEC é só
# [{ field, code }], de listas fechadas. A resposta crua é lida em memória para
# classificar e descartada: nada de mensagem, valor, nome ou data. Chave de
# errosValidacao fora da lista vira "other" (uma chave também poderia carregar
# dado). O código sai de palavras da mensagem, nunca do texto.
module Ledi
  module ErrorCodes
    FIELDS = %w[uuidFicha headerTransport profissionalCNS cboCodigo_2002 cnes ine dataAtendimento codigoIbgeMunicipio
                cpfCidadao cnsCidadao cns dataNascimento dtNascimento sexo turno localDeAtendimento localAtendimento
                tipoAtendimento condutas problemasCondicoes ciap medicoes procedimentos dataHoraInicialAtendimento
                dataHoraFinalAtendimento transport other].freeze
    CODES = %w[required invalid not_allowed out_of_range duplicate http_error unreachable invalid_url login_failed
               internal_error unknown].freeze
    UNKNOWN = { "field" => "other", "code" => "unknown" }.freeze
    MAX = 20

    module_function

    def from_rejection(body)
      parsed = parse(body)
      return [ UNKNOWN.dup ] unless parsed.is_a?(Hash)

      codes = pairs(parsed["errosValidacao"], nil).map { |path, message| { "field" => field_for(path), "code" => code_for(message) } }
      codes = [ { "field" => "other", "code" => code_for(parsed["descricaoErro"]) } ] if codes.empty?
      codes.uniq.first(MAX)
    end

    def transport(code) = [ { "field" => "transport", "code" => CODES.include?(code.to_s) ? code.to_s : "unknown" } ]

    def valid?(codes)
      codes.is_a?(Array) && codes.all? do |c|
        c.is_a?(Hash) && c.keys.map(&:to_s).sort == %w[code field] &&
          FIELDS.include?(c.with_indifferent_access[:field]) && CODES.include?(c.with_indifferent_access[:code])
      end
    end

    # "atendimentosIndividuais[0].cpfCidadao" → "cpfCidadao"; nada conhecido → "other".
    def field_for(path)
      path.to_s.split(/[.\[\]]+/).reverse.find { |segment| FIELDS.include?(segment) } || "other"
    end

    def code_for(message)
      text = I18n.transliterate(message.to_s.downcase)
      case text
      when /obrigatori|requerid|nao (foi )?(informad|preenchid)|ausente/ then "required"
      when /duplicad|ja (foi )?(enviad|recebid|cadastrad)/ then "duplicate"
      when /maxim|minim|fora (do|da) (faixa|intervalo)|superior|inferior|posterior|anterior/ then "out_of_range"
      when /nao (e |eh )?permitid|nao pode|nao aceit/ then "not_allowed"
      when /invalid|incorret|formato/ then "invalid"
      else "unknown"
      end
    end

    def parse(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      nil
    end

    def pairs(node, prefix)
      case node
      when Hash then node.flat_map { |k, v| pairs(v, [ prefix, k ].compact.join(".")) }
      when Array then node.flat_map { |v| pairs(v, prefix) }
      when nil then []
      else [ [ prefix, node ] ]
      end
    end
    private_class_method :parse, :pairs
  end
end
