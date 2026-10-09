# app/services/signatures/jcs.rb
# JSON Canonicalization Scheme (RFC 8785): o que se assina em CAdES é ESTA
# serialização (ADR 0032). Chaves ordenadas por unidades UTF-16; números na
# forma do Number.prototype.toString do ECMAScript; strings com só os escapes
# obrigatórios (aspas, barra invertida e controles < 0x20). Prova byte a byte
# contra o vetor do contracts em spec/services/signatures/canonical_vector_spec.rb.
module Signatures
  module Jcs
    class Unsupported < StandardError; end

    MAX_SAFE_INTEGER = (2**53) - 1
    ESCAPES = { "\b" => "\\b", "\t" => "\\t", "\n" => "\\n", "\f" => "\\f", "\r" => "\\r", "\"" => "\\\"",
                "\\" => "\\\\" }.freeze

    module_function

    def dump(value)
      out = +""
      write(value, out)
      out
    end

    def write(value, out)
      case value
      when Hash then object(value, out)
      when Array
        out << "["
        value.each_with_index do |item, index|
          out << "," if index.positive?
          write(item, out)
        end
        out << "]"
      when String then string(value, out)
      when true then out << "true"
      when false then out << "false"
      when nil then out << "null"
      when Integer
        raise Unsupported, "inteiro fora do intervalo seguro" if value.abs > MAX_SAFE_INTEGER

        out << value.to_s
      when Float, BigDecimal then out << number(value.to_f)
      else raise Unsupported, "tipo fora do JSON: #{value.class}"
      end
    end

    def object(hash, out)
      pairs = hash.map { |key, item| [ key!(key), item ] }
      raise Unsupported, "chave repetida" if pairs.map(&:first).uniq.size != pairs.size

      out << "{"
      pairs.sort_by { |key, _item| key.encode("UTF-16BE").unpack("n*") }.each_with_index do |(key, item), index|
        out << "," if index.positive?
        string(key, out)
        out << ":"
        write(item, out)
      end
      out << "}"
    end

    def key!(key)
      raise Unsupported, "chave que não é texto" unless key.is_a?(String) || key.is_a?(Symbol)

      utf8(key.to_s)
    end

    # Texto ASCII em outra codificação (Time#iso8601 sai US-ASCII) é o mesmo
    # texto em UTF-8; qualquer outro byte fora do UTF-8 válido é recusado.
    def utf8(text)
      return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?
      return text.dup.force_encoding(Encoding::UTF_8) if text.ascii_only? && text.encoding.ascii_compatible?

      raise Unsupported, "texto que não é UTF-8 válido"
    end

    def string(text, out)
      text = utf8(text)
      out << "\""
      text.each_char do |char|
        escaped = ESCAPES[char]
        if escaped then out << escaped
        elsif char.ord < 0x20 then out << format("\\u%04x", char.ord)
        else out << char
        end
      end
      out << "\""
    end

    def number(float)
      raise Unsupported, "NaN ou infinito" unless float.finite?
      return "0" if float.zero?

      # Float#to_s do Ruby já dá os dígitos mais curtos que voltam ao mesmo
      # double (como o ECMAScript); só a notação muda.
      mantissa, exponent = float.abs.to_s.split("e")
      int, frac = mantissa.split(".")
      frac = "" if frac.nil? || frac == "0"
      point = (int == "0" ? -frac[/\A0*/].size : int.size) + exponent.to_i
      digits = (int + frac).sub(/\A0+/, "").sub(/0+\z/, "")
      (float.negative? ? "-" : "") + ecmascript(digits, point)
    end

    # Number::toString (ECMA-262 §6.1.6.1.20): k dígitos, ponto decimal em n.
    def ecmascript(digits, point)
      size = digits.size
      if size <= point && point <= 21 then digits + ("0" * (point - size))
      elsif point.positive? && point <= 21 then "#{digits[0, point]}.#{digits[point..]}"
      elsif point > -6 && point <= 0 then "0.#{'0' * -point}#{digits}"
      else
        exponent = point - 1
        mantissa = size == 1 ? digits : "#{digits[0]}.#{digits[1..]}"
        "#{mantissa}e#{exponent.negative? ? '-' : '+'}#{exponent.abs}"
      end
    end
    private_class_method :write, :object, :key!, :utf8, :string, :number, :ecmascript
  end
end
