# Campos BNAFAR do lote (módulo 27b, contrato §2; Q7, Q15, Q17, Q21): leitura
# do corpo da entrada e do complemento, o que falta para o envio e a
# comparação com o lote gravado. Sem escrita e sem trava.
#
# Q21: na vacina o CNPJ do fabricante NÃO é digitado (vem do YAML pela
# `manufacturer_key`): o corpo da vacina com `manufacturer_cnpj` ou
# `manufacturer_international` é `invalid_request` (com o path, para o cliente
# aprender), e `missing` aponta `manufacturer_cnpj` quando o YAML não tem CNPJ.
module Bnafar
  module LotFields
    COMMON_KEYS = %w[unit_price_cents anvisa_registration health_program ium ampp_code].freeze
    MANUFACTURER_KEYS = %w[manufacturer_cnpj manufacturer_international manufacturer].freeze
    MAX_IUMS = 100

    module_function

    # Chaves do corpo aceitas no domínio.
    def keys_for(domain)
      keys = COMMON_KEYS.dup
      keys += MANUFACTURER_KEYS unless domain == Stock::Domain::IMMUNOBIOLOGICAL
      keys
    end

    # -> [ { coluna(Symbol) => valor }, [ { path:, error: } ] ]. `raw` tem
    # chaves String; chave ausente ou nula = não informado. `required` exige o
    # que o envio pede (preço, fabricante, ANVISA, programa, e o AMPP só quando
    # o item tem VMP: `vmp_code`). `current_anvisa` é a ANVISA já gravada, para
    # o AMPP sozinho no complemento.
    def parse(raw, prefix:, stock_domain:, required:, vmp_code:, current_anvisa: nil)
      domain = stock_domain
      fields = {}
      problems = []
      path = ->(field) { prefix.blank? ? field : "#{prefix}.#{field}" }
      add = ->(field, error) { problems << { path: path.call(field), error: error.to_s } }

      read_price(raw, fields, add, required)
      if domain == Stock::Domain::IMMUNOBIOLOGICAL
        MANUFACTURER_KEYS.first(2).each { |key| add.call(key, :invalid_request) unless raw[key].nil? }
      else
        read_manufacturer(raw, fields, add, required)
      end
      read_anvisa(raw, fields, add, required)
      read_program(raw, fields, add, required)
      read_ium(raw, fields, add)
      read_ampp(raw, fields, add, stock_domain: domain, required: required, vmp_code: vmp_code, current_anvisa: current_anvisa)
      [ fields, problems ]
    end

    # O que falta para o envio -> [ String ] (nomes dos campos). `vmp_code`:
    # o VMP do item (nil = sem código, o AMPP não é exigido, Q15); sem ele, o
    # método busca (medicamento no catálogo, vacina no YAML).
    def missing(lot, vmp_code: :lookup)
      domain = Stock::Domain.of_lot(lot)
      vmp = vmp_code == :lookup ? vmp_of(lot, domain) : vmp_code
      found = []
      found << "unit_price_cents" if lot.unit_price_cents.nil?
      found << "manufacturer_cnpj" unless manufacturer_filled?(lot, domain)
      found << "anvisa_registration" if lot.anvisa_registration.nil?
      found << "health_program" if lot.health_program.nil?
      found << "ampp_code" if vmp.present? && lot.ampp_code.nil?
      found
    end

    # Campos preenchidos do lote + versão + o que falta (resposta do complemento).
    def lot_json(lot, vmp_code: :lookup)
      lot.bnafar_fields.merge("version" => lot.bnafar_version, "missing" => missing(lot, vmp_code: vmp_code))
    end

    # `fields` (de `parse`) contra o lote gravado -> [ { coluna => valor novo }, [ campo em conflito ] ].
    # Nulo vira valor; o preço troca; o resto já preenchido e diferente é conflito
    # (o guard do banco só aceita o complemento, Q7).
    def diff(lot, fields)
      changes = {}
      conflicts = []
      fields.each do |key, value|
        case key
        when :unit_price_cents
          changes[key] = value if lot.unit_price_cents != value
        when :manufacturer_cnpj
          if lot.manufacturer_international then conflicts << key
          elsif lot.manufacturer_cnpj.nil? then changes[key] = value
          elsif lot.manufacturer_cnpj != value then conflicts << key
          end
        when :manufacturer_international
          if lot.manufacturer_cnpj.present? then conflicts << key
          elsif !lot.manufacturer_international then changes[key] = true
          end
        when :manufacturer
          if lot.manufacturer.nil? then changes[key] = value
          elsif lot.manufacturer != value then conflicts << key
          end
        when :ium
          if lot.ium.nil? then changes[key] = value
          elsif lot.ium.sort != value.sort then conflicts << key
          end
        else
          current = lot[key]
          if current.nil? then changes[key] = value
          elsif current != value then conflicts << key
          end
        end
      end
      [ changes, conflicts ]
    end

    # Coerência da apresentação (AMPP) com a ANVISA e o VMP sobre o estado
    # MESCLADO (lote + `changes` do diff): chamar sob a trava do lote. Só vale
    # quando a mudança toca o AMPP ou a ANVISA. -> [ { field:, error: } ]
    def coherence(lot, changes, vmp_code:)
      return [] unless (changes.keys & %i[ampp_code anvisa_registration]).any?

      ampp = changes[:ampp_code] || lot.ampp_code
      presentation = ampp && ObmPresentation.active.find_by(ampp_code: ampp)
      return [] unless presentation

      anvisa = changes[:anvisa_registration] || lot.anvisa_registration
      found = []
      found << { field: "anvisa_registration", error: "anvisa_mismatch" } if anvisa && presentation.anvisa_registration.present? &&
                                                                              presentation.anvisa_registration != anvisa
      found << { field: "ampp_code", error: "ampp_not_in_vmp" } if vmp_code.present? && presentation.vmp_code != vmp_code
      found
    end

    # Duas leituras do mesmo lote no mesmo pedido: algum campo em comum difere.
    def conflict?(first, second)
      (first.keys & second.keys).any? { |key| normalize(first[key]) != normalize(second[key]) }
    end

    # ---- leitura do corpo --------------------------------------------------

    def read_price(raw, fields, add, required)
      value = raw["unit_price_cents"]
      if value.nil?
        add.call("unit_price_cents", :required) if required
      elsif value.is_a?(Integer) && Catalog::UNIT_PRICE_CENTS.cover?(value)
        fields[:unit_price_cents] = value
      else
        add.call("unit_price_cents", :invalid_request)
      end
    end

    # CNPJ OU internacional (com o nome em `manufacturer`, Q15).
    def read_manufacturer(raw, fields, add, required)
      international = raw["manufacturer_international"]
      add.call("manufacturer_international", :invalid_request) unless international.nil? || [ true, false ].include?(international)
      cnpj = raw["manufacturer_cnpj"]

      if international == true
        add.call("manufacturer_cnpj", :invalid_request) unless cnpj.nil?
        name = raw["manufacturer"]
        if name.nil? || (name.is_a?(String) && name.strip.empty?)
          add.call("manufacturer", :required)
        elsif name.is_a?(String) && name.strip.length <= Catalog::INTERNATIONAL_NAME_MAX
          fields[:manufacturer_international] = true
          fields[:manufacturer] = name.strip
        else
          add.call("manufacturer", :invalid_request)
        end
      elsif cnpj.nil?
        add.call("manufacturer_cnpj", :required) if required
      elsif (normalized = Cnpj.normalize(cnpj))
        fields[:manufacturer_cnpj] = normalized
      else
        add.call("manufacturer_cnpj", :invalid_cnpj)
      end
    end

    def read_anvisa(raw, fields, add, required)
      value = raw["anvisa_registration"]
      if value.nil?
        add.call("anvisa_registration", :required) if required
      elsif value.is_a?(String) && value.match?(Catalog::ANVISA)
        fields[:anvisa_registration] = value
      else
        add.call("anvisa_registration", :invalid_request)
      end
    end

    def read_program(raw, fields, add, required)
      value = raw["health_program"]
      if value.nil?
        add.call("health_program", :required) if required
      elsif !value.is_a?(String)
        add.call("health_program", :invalid_request)
      elsif programs.include?(value)
        fields[:health_program] = value
      else
        add.call("health_program", :program_unknown)
      end
    end

    def read_ium(raw, fields, add)
      value = raw["ium"]
      return if value.nil?

      valid = value.is_a?(Array) && value.size <= MAX_IUMS && value.all? { |ium| ium.is_a?(String) && ium.match?(Catalog::IUM) }
      if !valid then add.call("ium", :invalid_request)
      elsif value.any? then fields[:ium] = value.uniq
      end
    end

    def read_ampp(raw, fields, add, stock_domain:, required:, vmp_code:, current_anvisa:)
      domain = stock_domain
      value = raw["ampp_code"]
      if value.nil?
        add.call("ampp_code", :required) if required && vmp_code.present? && domain != Stock::Domain::VECTOR_CONTROL
        return
      end
      return add.call("ampp_code", :invalid_request) if domain == Stock::Domain::VECTOR_CONTROL
      return add.call("ampp_code", :invalid_request) unless value.is_a?(String) && value.match?(Catalog::AMPP)

      presentation = ObmPresentation.active.find_by(ampp_code: value)
      return add.call("ampp_code", :ampp_unknown) unless presentation
      return add.call("ampp_code", :ampp_not_in_vmp) if vmp_code.present? && presentation.vmp_code != vmp_code

      anvisa = fields[:anvisa_registration] || current_anvisa
      return add.call("anvisa_registration", :anvisa_mismatch) if anvisa && presentation.anvisa_registration.present? &&
                                                                  presentation.anvisa_registration != anvisa

      fields[:ampp_code] = value
    end

    def programs = Bnafar::Domains.programs.map { |program| program.fetch("code") }

    def normalize(value) = value.is_a?(Array) ? value.sort : value

    def manufacturer_filled?(lot, domain)
      return lot.manufacturer_international || lot.manufacturer_cnpj.present? unless domain == Stock::Domain::IMMUNOBIOLOGICAL

      product = Vaccination::Immunobiologicals.find(lot.immunobiological_code)
      product&.manufacturer(lot.manufacturer_key)&.cnpj.present?
    end

    def vmp_of(lot, domain)
      case domain
      when Stock::Domain::IMMUNOBIOLOGICAL then Vaccination::Immunobiologicals.find(lot.immunobiological_code)&.obm_vmp
      when Stock::Domain::VECTOR_CONTROL then nil
      else MedicationCatalogItem.where(id: lot.catalog_item_id).pick(:vmp_code)
      end
    end

    private_class_method :read_price, :read_manufacturer, :read_anvisa, :read_program, :read_ium, :read_ampp, :programs, :normalize,
                         :manufacturer_filled?, :vmp_of
  end
end
