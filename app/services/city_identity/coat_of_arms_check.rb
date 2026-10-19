# Valida o brasão da cidade pelos próprios bytes (assinatura + dimensões),
# sem confiar em content-type ou extensão enviados pelo cliente. Só PNG/WebP.
module CityIdentity
  class CoatOfArmsCheck
    MAX_BYTES = 262_144
    MIN_SIDE = 128
    MAX_SIDE = 1024
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

    def self.call(io) = new(io).call

    def initialize(io)
      @io = io
    end

    def call
      data = @io.read(MAX_BYTES + 1).to_s.b
      return Result.fail(:too_large) if data.bytesize > MAX_BYTES

      content_type, width, height = parse(data)
      return Result.fail(:invalid_format) unless content_type
      return Result.fail(:invalid_dimensions) unless valid_dimensions?(width, height)

      Result.ok(content_type: content_type, width: width, height: height, byte_size: data.bytesize)
    end

    private

    def parse(data)
      if data.bytesize >= 24 && data.start_with?(PNG_SIGNATURE) && data.byteslice(12, 4) == "IHDR"
        [ "image/png", *data.byteslice(16, 8).unpack("NN") ]
      elsif data.bytesize >= 25 && data.byteslice(0, 4) == "RIFF" && data.byteslice(8, 4) == "WEBP"
        webp_dimensions(data)
      end
    end

    def webp_dimensions(data)
      dims =
        case data.byteslice(12, 4)
        when "VP8X"
          return nil if data.bytesize < 30

          w = data.byteslice(24, 3).unpack("C3")
          h = data.byteslice(27, 3).unpack("C3")
          [ le24(w) + 1, le24(h) + 1 ]
        when "VP8L"
          return nil unless data.getbyte(20) == 0x2f

          bits = data.byteslice(21, 4).unpack1("V")
          [ (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1 ]
        when "VP8 "
          return nil if data.bytesize < 30

          return nil unless data.byteslice(23, 3) == "\x9d\x01\x2a".b

          data.byteslice(26, 4).unpack("vv").map { |v| v & 0x3fff }
        end
      dims && [ "image/webp", *dims ]
    end

    def le24(bytes) = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16)

    def valid_dimensions?(width, height)
      [ width, height ].min >= MIN_SIDE && [ width, height ].max <= MAX_SIDE
    end
  end
end
