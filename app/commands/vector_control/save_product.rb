# Cadastro do produto de campo pela coordenação (módulo 35a, ADR 0054;
# contrato §4; Q15). Corpo `{ code, name, unit, charge_size, uses, active? }`
# (no PATCH, só as chaves que mudam): `code` 1–10 caracteres, único sem
# diferenciar caixa; `name` 1–80; `unit` g, ml ou un; `charge_size` decimal em
# TEXTO, até 8 inteiros e 2 casas, > 0; `uses` lista não vazia, sem repetição,
# de focal/perifocal/spatial; `active` booleano. Texto longo recusado, nunca
# cortado. Toda recusa de campo é `invalid_request` com o `path` do campo.
#
# Módulo 35b (Q11): `uses` aceita também rabies_vaccine e collar
# (Catalog::ALL_PRODUCT_USES), só com o zoonoses utilizável (`zoonoses:`, lido
# pelo controller fora da transação) e sempre numa finalidade só, com `unit`
# un e `charge_size` 1.00 — conferido no produto como fica depois da escrita
# (no PATCH, as chaves que mudam sobre as gravadas). Fora disso,
# `invalid_request` path `uses` (o CHECK ck_vector_products_zoonoses_uses é o
# cinto). O PATCH nunca troca a família do produto: o `uses` de um produto de
# zoonoses não muda, e o vetorial nunca ganha finalidade de zoonoses (path
# `uses`).
#
# `unit` e `charge_size` não mudam depois que há lote ou medida do produto →
# 409 product_in_use (para isso se cria outro produto). A edição trava o
# produto FOR UPDATE e só então confere o uso: a entrada do 27a e o boletim
# tomam FOR SHARE no produto antes de criar lote ou medida, então nenhum lote
# ou medida nasce entre a conferência e a gravação (o trigger
# rota_vector_product_guard é o cinto, sem trava). version + 1 a cada escrita;
# `vector_product.changed` só com ids, só quando algo mudou.
#
# Módulo 27b (Q13, Q23): `catmat_code` (Integer > 0 ou null), o CATMAT enviado à
# BNAFAR; dado de origem, exige só o estoque vetorial (nunca o `bnafar`).
module VectorControl
  module SaveProduct
    KEYS = %w[code name unit charge_size uses active catmat_code].freeze
    REQUIRED = %w[code name unit charge_size uses].freeze
    FIXED = %w[unit charge_size].freeze
    CHARGE_SIZE = /\A\d{1,8}(\.\d{1,2})?\z/
    CODE_INDEX = "idx_vector_products_code".freeze
    IN_USE = /unit and charge_size are fixed once the product is in use/
    EVENT = "vector_product.changed".freeze
    ZOONOSES_CHECK = "ck_vector_products_zoonoses_uses".freeze

    module_function

    # -> Result.ok(product:) | fail(:invalid_request, details: { path: }) | fail(:product_in_use)
    def call(params:, by:, product: nil, zoonoses: false)
      params = params.to_h.stringify_keys
      unknown = (params.keys - KEYS).first
      return invalid(unknown) if unknown

      missing = product ? nil : REQUIRED.find { |key| !params.key?(key) }
      return invalid(missing) if missing

      attrs, path = parse(params)
      return invalid(path) if path
      return invalid("uses") unless zoonoses_rule?(attrs, product, zoonoses)

      product ? update(product, attrs, by) : create(attrs, by)
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(CODE_INDEX)

      invalid("code")
    rescue ActiveRecord::StatementInvalid => e
      # A regra da Q11 foi lida sobre o produto antes da trava: uma edição
      # concorrente que a quebre cai no CHECK, recusada como a regra.
      return invalid("uses") if e.message.include?(ZOONOSES_CHECK)
      raise unless e.message.match?(IN_USE)

      Result.fail(:product_in_use)
    end

    def create(attrs, by)
      VectorProduct.transaction(requires_new: true) do
        next invalid("code") if code_taken?(attrs[:code])

        product = VectorProduct.create!(attrs.reverse_merge(active: true))
        DomainEvents.publish(EVENT, vector_product_id: product.id, user_id: by.id)
        Result.ok(product: product)
      end
    end

    def update(product, attrs, by)
      VectorProduct.transaction(requires_new: true) do
        locked = VectorProduct.lock.find(product.id)
        locked.assign_attributes(attrs)
        next Result.ok(product: locked) unless locked.changed?
        next invalid("code") if locked.code_changed? && code_taken?(locked.code, except: locked.id)
        next Result.fail(:product_in_use) if FIXED.any? { |key| locked.attribute_changed?(key) } && in_use?(locked)

        locked.version += 1
        locked.save!
        DomainEvents.publish(EVENT, vector_product_id: locked.id, user_id: by.id)
        Result.ok(product: locked)
      end
    end

    # -> [ { atributo => valor }, path | nil ]
    def parse(params)
      attrs = {}
      params.each do |key, value|
        parsed = parse_value(key, value)
        return [ nil, key ] if parsed.nil?

        attrs[key.to_sym] = parsed == :clear ? nil : parsed
      end
      [ attrs, nil ]
    end

    # -> valor gravável | nil (recusado)
    def parse_value(key, value)
      case key
      when "code" then text(value, Catalog::PRODUCT_CODE)
      when "name" then text(value, Catalog::PRODUCT_NAME)
      when "unit" then value if Catalog::UNITS.include?(value)
      when "charge_size"
        size = value.is_a?(String) && value.match?(CHARGE_SIZE) ? BigDecimal(value) : nil
        size if size&.positive?
      when "uses"
        value if value.is_a?(Array) && value.any? && value.uniq.size == value.size && value.all? { |use| Catalog::ALL_PRODUCT_USES.include?(use) }
      when "active" then value if [ true, false ].include?(value)
      # Módulo 27b (Q13): `null` limpa e é válido; o nil de "recusado" não o
      # distingue, por isso o :clear (parse o troca por nil).
      when "catmat_code" then value.nil? ? :clear : (value if value.is_a?(Integer) && value.positive? && value <= 2_147_483_647)
      end
    end

    # Q11: finalidade de zoonoses só com o zoonoses utilizável (quando a
    # escrita a traz) e sozinha, em un com carga 1.00 (no produto final). O
    # PATCH nunca troca a família: o `uses` de um produto de zoonoses não muda,
    # e um produto vetorial nunca ganha finalidade de zoonoses (senão a vacina
    # entraria no boletim e no enum da v1.3.0, ou o contrário).
    def zoonoses_rule?(attrs, product, zoonoses)
      uses = attrs.fetch(:uses) { product&.uses } || []
      if product && attrs.key?(:uses)
        return false if zoonoses_product?(product.uses) ? attrs[:uses] != product.uses : zoonoses_product?(uses)
      end
      return true unless zoonoses_product?(uses)
      return false if attrs.key?(:uses) && !zoonoses

      unit = attrs.fetch(:unit) { product&.unit }
      charge_size = attrs.fetch(:charge_size) { product&.charge_size }
      uses.size == 1 && unit == "un" && charge_size == 1
    end

    def zoonoses_product?(uses) = uses.intersect?(Zoonoses::Catalog::PRODUCT_USES)

    def text(value, range)
      return nil unless value.is_a?(String)

      clean = value.strip
      range.cover?(clean.length) ? clean : nil
    end

    def code_taken?(code, except: nil)
      scope = VectorProduct.where("lower(code) = lower(?)", code)
      (except ? scope.where.not(id: except) : scope).exists?
    end

    def in_use?(product)
      StockLot.exists?(vector_product_id: product.id) || VectorInspectionMeasure.exists?(vector_product_id: product.id)
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :create, :update, :parse, :parse_value, :zoonoses_rule?, :zoonoses_product?, :text, :code_taken?, :in_use?, :invalid
  end
end
