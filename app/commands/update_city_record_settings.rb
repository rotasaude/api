# Modo de prontuário, endereço do PEC e código IBGE de uma cidade, pelo operador
# no console (ADR 0028; spec 2026-10-05 §3.2; contratos §4.1). Valida TUDO antes
# de escrever: um corpo com qualquer campo inválido não grava nada. O IBGE mora
# no city_profile do banco da cidade (fonte única); modo e PEC, na plataforma.
# A cidade é escrita primeiro: se ela não responde, a plataforma não muda.
# null e "" limpam PEC e IBGE; record_mode nunca é nulo.
# Reasons: :invalid_city (linha da cidade inválida por outra regra), :invalid_record_mode, :invalid_ibge_code, :invalid_pec_url, :city_unreachable.
class UpdateCityRecordSettings
  FIELDS = %w[record_mode ibge_code pec_url].freeze
  IBGE_CODE = /\A\d{7}\z/

  def self.call(city:, attrs:)
    attrs = attrs.to_h.stringify_keys.slice(*FIELDS).transform_values { |v| v == "" ? nil : v }
    error = invalid(attrs)
    return Result.fail(error) if error

    # Atribui e valida a linha da plataforma ANTES de tocar o banco da cidade:
    # assim o IBGE (que commita na cidade) nunca fica meio aplicado por uma
    # validação da City que falharia depois.
    city.assign_attributes(attrs.slice("record_mode", "pec_url"))
    return Result.fail(:invalid_city) unless city.valid?

    changed = []
    if attrs.key?("ibge_code")
      return Result.fail(:city_unreachable) unless city.servable?

      changed << "ibge_code" if write_ibge_code(city, attrs["ibge_code"])
    end

    changed.concat(city.changed & %w[record_mode pec_url])
    city.save!
    changed.sort!
    Platform.audit("city.record_settings_changed", city_id: city.id, fields: changed) if changed.any?
    Result.ok(city: city, changed: changed)
  rescue *Maintenance::CityConnectionErrors::CLASSES
    Result.fail(:city_unreachable)
  end

  def self.invalid(attrs)
    return :invalid_record_mode if attrs.key?("record_mode") && !City::RECORD_MODES.include?(attrs["record_mode"])
    if attrs.key?("ibge_code") && !(attrs["ibge_code"].nil? || (attrs["ibge_code"].is_a?(String) && attrs["ibge_code"].match?(IBGE_CODE)))
      return :invalid_ibge_code
    end

    :invalid_pec_url if attrs.key?("pec_url") && !(attrs["pec_url"].nil? || City.valid_pec_url?(attrs["pec_url"]))
  end

  # true se mudou. A linha única do city_profile nasce no provisionamento; se
  # faltar (cidade antiga), nasce aqui com o nome e a UF do catálogo.
  def self.write_ibge_code(city, value)
    CityConnection.with(city) do
      profile = CityProfile.current || CityProfile.new(name: city.name, uf: city.uf&.upcase)
      profile.ibge_code = value
      next false unless profile.new_record? || profile.changed?

      profile.save!
      true
    end
  end

  private_class_method :invalid, :write_ibge_code
end
