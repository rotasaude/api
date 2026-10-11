# Endereço completo da RCE/RET (ADR 0034; Lei 5.991, art. 35; Valores fixados
# 2): do prescritor (perfil) e do paciente (digitado na receita). Devolve o
# campo exato que falhou; nunca loga o valor. Caractere de controle (NUL, BEL…)
# no valor digitado é recusado, mesmo na ponta (o strip do Ruby comeria o NUL
# final calado); quebra de linha e tab continuam virando espaço no squish.
module ClinicalDocuments
  module Address
    LIMITS = { "street" => 1..120, "number" => 1..10, "district" => 1..80, "city" => 1..80 }.freeze
    COMPLEMENT = 1..60
    CONTROL = /[[:cntrl:]&&[^[:space:]]]/

    module_function

    def normalize(value)
      return [ nil, "address" ] unless value.is_a?(Hash) || value.respond_to?(:to_unsafe_h)

      value = (value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h).transform_keys(&:to_s)
      out = {}
      LIMITS.each do |key, range|
        raw = value[key].is_a?(String) ? value[key] : ""
        text = raw.squish
        return [ nil, key ] unless range.cover?(text.size) && !raw.match?(CONTROL)

        out[key] = text
      end
      raw = value["complement"].is_a?(String) ? value["complement"] : ""
      complement = raw.squish
      return [ nil, "complement" ] if complement.size > COMPLEMENT.max || raw.match?(CONTROL)

      out["complement"] = complement if complement.present?
      # Formatos do esquema (clinical-v1.2.0): sem máscara, uma representação por valor.
      uf = value["uf"]
      return [ nil, "uf" ] unless uf.is_a?(String) && uf.match?(/\A[A-Z]{2}\z/) && Professional::UFS.include?(uf)

      zip = value["zip"]
      return [ nil, "zip" ] unless zip.is_a?(String) && zip.match?(/\A[0-9]{8}\z/)

      [ out.merge("uf" => uf, "zip" => zip).slice("street", "number", "complement", "district", "city", "uf", "zip"), nil ]
    end

    def phone(value) = value.is_a?(String) && value.match?(/\A[0-9]{10,11}\z/) ? value : nil

    def line(address)
      return "" unless address.is_a?(Hash)

      street = [ address["street"], address["number"], address["complement"] ].compact_blank.join(", ")
      zip = address["zip"].to_s.sub(/\A(\d{5})(\d{3})\z/, '\1-\2')
      "#{street} — #{address['district']} — #{address['city']}/#{address['uf']} — CEP #{zip}"
    end
  end
end
