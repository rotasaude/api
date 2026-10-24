# Endereço do domicílio (módulo 24a, ADR 0042; contrato §2, L6/R3; plano,
# Desvio 8): os limites são o MENOR entre o LEDI (enderecoLocalPermanencia) e
# o BPA-I do módulo 22 — logradouro 30, número 5, complemento 10, bairro 30 —
# porque o endereço do domicílio é regravado nos pacientes moradores e vai no
# BPA-I deles. Mais longo → 422 invalid_household com o caminho, nunca cortado.
# O nome do logradouro não repete o tipo DNE escolhido (address.street).
module TerritoryRegistry
  module Address
    KEYS = %w[zip street_type street number no_number complement neighborhood_id district reference].freeze
    STREET_MAX = 30
    NUMBER = /\A[A-Za-z0-9]{1,5}\z/
    COMPLEMENT_MAX = 10
    DISTRICT_MAX = 30
    REFERENCE_MAX = 40
    ZIP = /\A\d{8}\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    NO_NUMBER = "SN"

    module_function

    # values: as chaves de KEYS (number nil com no_number true; district nil
    # sem texto). neighborhood_id: bairro ativo do cadastro de bairros (módulo
    # 11) com nome que cabe no BPA; sem bairro, district obrigatório.
    def parse(raw)
      return invalid("address") unless raw.is_a?(Hash)

      raw = raw.to_h.stringify_keys
      unknown = (raw.keys - KEYS).first
      return invalid("address.#{unknown}") if unknown
      return invalid("address.no_number") unless [ true, false, nil ].include?(raw["no_number"])

      text = KEYS.excluding("no_number").to_h { |key| [ key, raw[key] ] }
      bad = text.find { |_key, value| !value.nil? && !value.is_a?(String) }
      return invalid("address.#{bad.first}") if bad

      text.transform_values! { |value| value&.squish.presence }
      no_number = raw["no_number"] == true
      path = check(text, no_number)
      return invalid(path) if path

      Result.ok(values: text.merge("no_number" => no_number).slice(*KEYS))
    end

    # Chaves de endereço de Patient::DEMOGRAPHICS (Desvio 8): bairro pelo nome
    # do cadastro de bairros, ou o texto district; "SN" sem número.
    def to_patient(address, neighborhood:)
      address = address.to_h.stringify_keys
      { "address_zip" => address["zip"], "address_street" => address["street"],
        "address_number" => address["no_number"] ? NO_NUMBER : address["number"],
        "address_complement" => address["complement"],
        "address_district" => neighborhood&.name || address["district"] }
    end

    def check(text, no_number)
      # cep: 8 dígitos
      ("address.zip" unless text["zip"]&.match?(ZIP)) ||
        # tipoLogradouroNumeroDne: domínio texto tipo_logradouro (DNE)
        ("address.street_type" unless Dictionary.string_domain("tipo_logradouro").key?(text["street_type"])) ||
        # nomeLogradouro: obrigatório, até 30 (BPA), sem repetir o tipo
        ("address.street" if text["street"].nil? || text["street"].length > STREET_MAX) ||
        ("address.street" if repeats_type?(text["street"], text["street_type"])) ||
        # numero: 1–5 letras e dígitos (BPA); proibido com stSemNumero, obrigatório sem
        ("address.number" if no_number ? text["number"] : !text["number"]&.match?(NUMBER)) ||
        # complemento: até 10 (BPA)
        ("address.complement" if text["complement"] && text["complement"].length > COMPLEMENT_MAX) ||
        # pontoReferencia: até 40
        ("address.reference" if text["reference"] && text["reference"].length > REFERENCE_MAX) ||
        # bairro: do cadastro de bairros, ativo, nome até 30 (BPA)
        ("address.neighborhood_id" if text["neighborhood_id"] && !usable_neighborhood?(text["neighborhood_id"])) ||
        # bairro em texto: obrigatório sem bairro do cadastro, até 30 (BPA)
        ("address.district" if text["neighborhood_id"].nil? && text["district"].nil?) ||
        ("address.district" if text["district"] && text["district"].length > DISTRICT_MAX)
    end

    # O nome do logradouro começa com o nome do tipo DNE escolhido (palavra
    # inteira, sem acento nem caixa): "Rua das Acácias" com tipo RUA (revisão
    # final, M4) — o tipo vai em tipoLogradouroNumeroDne, o nome sem ele.
    def repeats_type?(street, street_type)
      type = Dictionary.string_domain("tipo_logradouro")[street_type]
      return false if type.nil?

      fold(street).match?(/\A#{Regexp.escape(fold(type))}(?![[:alnum:]])/)
    end

    def fold(text) = ActiveSupport::Inflector.transliterate(text.unicode_normalize(:nfc)).upcase

    def usable_neighborhood?(id)
      return false unless id.match?(UUID)

      name = Neighborhood.active_neighborhoods.where(id: id).pick(:name)
      name.present? && name.length <= DISTRICT_MAX
    end

    def invalid(path) = Result.fail(:invalid_household, details: { path: path })
    private_class_method :check, :repeats_type?, :fold, :usable_neighborhood?, :invalid
  end
end
