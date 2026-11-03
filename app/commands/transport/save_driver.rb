# Cadastra e edita motoristas (ADR 0048; contrato §4, T3). O usuário precisa ter
# a Membership `driver` ativa (`user_not_driver` 422) e ainda não ter cadastro
# (`user_already_driver` 409); o usuário nunca muda depois. CNH de 11 dígitos
# (cifrada), categoria B/C/D/E e validade (data real; vencida é aceita — o
# status diz). Todas as recusas de campo de uma vez. Nunca se apaga:
# desativa-se. Evento só com ids; a CNH não vai a lugar nenhum.
module Transport
  module SaveDriver
    KEYS = %w[user_id license_number license_category license_expires_on active].freeze

    module_function

    # -> Result.ok(driver:) | fail(:invalid_request, details: { path:, problems: }) |
    # fail(:user_not_driver) | fail(:user_already_driver)
    def call(attrs:, by:, record: nil)
      attrs = attrs.to_h.stringify_keys
      unknown = Support.unknown_keys(attrs, KEYS)
      return Support.refuse(unknown) if unknown.any?

      clean, bad = validate(attrs, record)
      return Support.refuse(bad) if bad.any?

      TransportDriver.transaction(requires_new: true) do
        driver = record || TransportDriver.new
        driver.lock! if record
        unless record
          refusal = user_refusal(attrs["user_id"])
          next refusal if refusal

          driver.user_id = attrs["user_id"]
        end
        driver.assign_attributes(clean)
        next Result.ok(driver: driver) if record && !driver.changed?

        driver.updated_by_user = by
        driver.save!
        DomainEvents.publish("transport.driver_saved", driver_id: driver.id, user_id: by.id)
        Result.ok(driver: driver)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:user_already_driver)
    end

    # -> [valores limpos, caminhos recusados]. Na criação tudo é obrigatório;
    # na edição só o que veio (o usuário não muda).
    def validate(attrs, record)
      clean = {}
      bad = []
      bad << "user_id" if record ? attrs.key?("user_id") && attrs["user_id"] != record.user_id : !attrs["user_id"].is_a?(String)
      field(clean, bad, attrs, "license_number", record) do |v|
        v = v.is_a?(String) ? v.strip : nil
        v&.match?(Catalog::LICENSE_NUMBER) ? v : nil
      end
      field(clean, bad, attrs, "license_category", record) { |v| Catalog::LICENSE_CATEGORIES.include?(v) ? v : nil }
      field(clean, bad, attrs, "license_expires_on", record) { |v| Support.date(v) }
      if attrs.key?("active") || !record
        value = attrs.fetch("active", true)
        Support.boolean?(value) ? clean["active"] = value : bad << "active"
      end
      [ clean, bad ]
    end

    def field(clean, bad, attrs, key, record)
      return if record && !attrs.key?(key)

      value = yield(attrs[key])
      value.nil? ? bad << key : clean[key] = value
    end

    # Papel `driver` ativo e sem cadastro. Usuário inexistente ou desativado
    # conta como sem papel (a resposta não diz se o id existe).
    def user_refusal(user_id)
      user = User.find_by(id: user_id)
      return Support.refuse_with(:user_not_driver, "user_id") unless user&.active? && user.has_role?("driver")
      return Support.refuse_with(:user_already_driver, "user_id") if TransportDriver.exists?(user_id: user.id)

      nil
    end

    private_class_method :validate, :field, :user_refusal
  end
end
