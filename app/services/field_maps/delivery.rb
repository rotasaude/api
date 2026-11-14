# Entrega do arquivo de mapa (módulo 24c, ADR 0053; contrato §3.1, Q34): decide,
# pelos cabeçalhos da requisição, se vai o arquivo inteiro, um intervalo, 304 ou
# 416 — sem tocar o arquivo — e rende o corpo em pedaços, lendo só o que foi
# pedido. O ETag é o SHA-256 do arquivo.
#
#   - If-None-Match que contém o ETag (com aspas, sem, `W/`, em lista ou `*`) → 304;
#   - sem Range, com mais de um intervalo ou com outra unidade → 200 inteiro;
#   - If-Range presente e diferente do ETag → ignora o Range: 200 inteiro (o
#     arquivo mudou; quem continuava um download recomeça);
#   - um intervalo `bytes=a-b`, `bytes=a-` ou `bytes=-n` → 206;
#   - intervalo impossível → 416 com `Content-Range: bytes */<tamanho>`.
module FieldMaps
  module Delivery
    Plan = Struct.new(:status, :headers, :offset, :length, keyword_init: true)

    SINGLE = /\Abytes=([^,]*)\z/
    SPEC = /\A(\d*)-(\d*)\z/

    # Corpo Rack: os bytes [offset, offset + length) em pedaços de MAP_CHUNK.
    class Body
      def initialize(key, offset, length)
        @key = key
        @offset = offset
        @length = length
      end

      def each
        position = @offset
        finish = @offset + @length
        while position < finish
          last = [ position + FieldSync::Catalog::MAP_CHUNK, finish ].min - 1
          yield Storage.chunk(@key, position..last)
          position = last + 1
        end
      end
    end

    module_function

    def plan(map:, range:, if_none_match:, if_range: nil)
      size = map.size_bytes
      etag = %("#{map.sha256}")
      headers = { "ETag" => etag, "Accept-Ranges" => "bytes", "Content-Type" => FieldSync::Catalog::MAP_CONTENT_TYPE,
                  "Cache-Control" => "private, no-cache" }
      return Plan.new(status: 304, headers: headers, offset: 0, length: 0) if matches?(if_none_match, map.sha256)

      spec = range.to_s[SINGLE, 1]
      spec = nil if if_range.present? && if_range.strip != etag
      return whole(headers, size) if spec.nil?

      first, last = bounds(spec.strip, size)
      unless first
        return Plan.new(status: 416, headers: headers.merge("Content-Range" => "bytes */#{size}"), offset: 0, length: 0)
      end

      length = last - first + 1
      Plan.new(status: 206, offset: first, length: length,
               headers: headers.merge("Content-Range" => "bytes #{first}-#{last}/#{size}", "Content-Length" => length.to_s))
    end

    def whole(headers, size) = Plan.new(status: 200, headers: headers.merge("Content-Length" => size.to_s), offset: 0, length: size)

    # -> [primeiro, último] dentro do arquivo, ou nil se o intervalo é impossível.
    def bounds(spec, size)
      from, to = spec.match(SPEC)&.captures
      return nil if from.nil? || (from.empty? && to.empty?)

      if from.empty? # sufixo: os últimos n bytes
        count = to.to_i
        return nil if count.zero?

        return [ [ size - count, 0 ].max, size - 1 ]
      end

      first = from.to_i
      last = to.empty? ? size - 1 : [ to.to_i, size - 1 ].min
      first < size && first <= last ? [ first, last ] : nil
    end

    def matches?(if_none_match, sha)
      value = if_none_match.to_s.strip
      return false if value.empty?
      return true if value == "*"

      value.split(",").any? { |tag| tag.strip.delete_prefix("W/").delete('"') == sha }
    end

    private_class_method :whole, :bounds, :matches?
  end
end
