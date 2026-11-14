# Módulo 24c (ADR 0053; contrato §4, Q3): a coordenada do imóvel (ficha 3) e
# da visita (ficha 8), validada num lugar só. Puro, sem banco.
#
# Latitude -90..90 e longitude -180..180 com até 8 casas (dicionário do LEDI
# 8.7.0, fcd e fvd); accuracy_m 0..10000 com até 1 casa, obrigatório quando a
# origem é o GPS do aparelho e opcional no ponto marcado no mapa. Mais casas
# do que o limite recusa: nunca arredonda.
#
# Sigilo: a recusa leva só o `path`. O valor recusado nunca vai a
# `Result.details`, mensagem, log ou evento.
module FieldLocation
  REQUIRED = %w[latitude longitude source].freeze
  OPTIONAL = %w[accuracy_m].freeze
  ACCURACY_REQUIRED_SOURCES = %w[gps].freeze
  LATITUDE = (-90..90)
  LONGITUDE = (-180..180)
  DECIMALS = 8
  ACCURACY = (0..10_000)
  ACCURACY_DECIMALS = 1
  SOURCES = %w[gps map].freeze
  VISIT_SOURCES = %w[gps].freeze

  module_function

  # -> Result.ok(location: Hash | nil) | Result.fail(:invalid_location, details: { path: })
  def parse(raw, sources:, prefix: "location")
    return Result.ok(location: nil) if raw.nil?
    return refuse(prefix) unless raw.is_a?(Hash) && (raw.keys - REQUIRED - OPTIONAL).empty?

    return refuse("#{prefix}.latitude") unless coordinate?(raw["latitude"], LATITUDE, DECIMALS)
    return refuse("#{prefix}.longitude") unless coordinate?(raw["longitude"], LONGITUDE, DECIMALS)

    source = raw["source"]
    return refuse("#{prefix}.source") unless source.is_a?(String) && sources.include?(source)

    accuracy = raw["accuracy_m"]
    if raw.key?("accuracy_m") ? !coordinate?(accuracy, ACCURACY, ACCURACY_DECIMALS) : ACCURACY_REQUIRED_SOURCES.include?(source)
      return refuse("#{prefix}.accuracy_m")
    end

    location = { "latitude" => raw["latitude"].to_f, "longitude" => raw["longitude"].to_f }
    location["accuracy_m"] = accuracy.to_f if raw.key?("accuracy_m")
    Result.ok(location: location.merge("source" => source))
  end

  # Casas decimais da forma mais curta que volta ao mesmo número (1.0e-09 → 9).
  def decimals(number)
    BigDecimal(number.to_s).scale
  end

  # O par para as fichas 3 e 8 do LEDI; nada sem coordenada.
  def ledi(location)
    return {} if location.nil?

    { latitude: location.fetch("latitude").to_f, longitude: location.fetch("longitude").to_f }
  end

  def coordinate?(value, range, max_decimals)
    return false unless value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)

    range.cover?(value) && decimals(value) <= max_decimals
  end

  def refuse(path) = Result.fail(:invalid_location, details: { path: path })

  private_class_method :coordinate?, :refuse
end
