# <location> do procedimento e do item do plano (ADR 0046; Desvio 6; contrato
# §16 O25): tooth exige o dente; face, o dente e a face; sextant, S1–S6; arch,
# upper/lower; mouth, nada. Campo de outro tipo só nulo. O dente chega inteiro
# ou string de dígitos e sai inteiro. Recusa sem eco do valor (dado clínico).
module DentalCare
  module Location
    FIELDS = %i[tooth face sextant arch].freeze
    REQUIRED = { "tooth" => %i[tooth], "face" => %i[tooth face], "sextant" => %i[sextant], "arch" => %i[arch], "mouth" => [] }.freeze
    TEETH = (Catalog::PERMANENT_TEETH + Catalog::DECIDUOUS_TEETH).freeze

    UPPER = [ *11..18, *21..28, *51..55, *61..65 ].freeze
    LOWER = [ *31..38, *41..48, *71..75, *81..85 ].freeze
    SEXTANTS = {
      "S1" => [ *14..18, 54, 55 ], "S2" => [ 11, 12, 13, 21, 22, 23, 51, 52, 53, 61, 62, 63 ], "S3" => [ *24..28, 64, 65 ],
      "S4" => [ *34..38, 74, 75 ], "S5" => [ 31, 32, 33, 41, 42, 43, 71, 72, 73, 81, 82, 83 ], "S6" => [ *44..48, 84, 85 ]
    }.freeze

    module_function

    def parse(raw)
      return invalid unless raw.is_a?(Hash)

      raw = raw.to_h.transform_keys(&:to_s)
      kind = raw["kind"]
      return invalid unless kind.is_a?(String) && REQUIRED.key?(kind)

      location = { kind: kind, tooth: tooth(raw["tooth"]), face: raw["face"], sextant: raw["sextant"], arch: raw["arch"] }
      required = REQUIRED.fetch(kind)
      return invalid if (FIELDS - required).any? { |field| !raw[field.to_s].nil? }
      return invalid unless required.all? { |field| valid_field?(field, location[field]) }

      Result.ok(location: location)
    end

    # Os dentes que o local cobre (permanentes e decíduos).
    def teeth(location)
      case location.fetch(:kind)
      when "tooth", "face" then [ location.fetch(:tooth) ]
      when "sextant" then SEXTANTS.fetch(location.fetch(:sextant))
      when "arch" then location.fetch(:arch) == "upper" ? UPPER : LOWER
      else TEETH
      end
    end

    def tooth(value)
      code = Ledi::ConsultationMapping.code(value)
      code if TEETH.include?(code)
    end

    def valid_field?(field, value)
      case field
      when :tooth then !value.nil?
      when :face then Catalog::FACES.include?(value)
      when :sextant then Catalog::SEXTANTS.include?(value)
      when :arch then Catalog::ARCHES.include?(value)
      end
    end

    def invalid = Result.fail(:invalid_location)
    private_class_method :tooth, :valid_field?, :invalid
  end
end
