# upsertCareLineTemplate (contrato §8): toda gravação é a versão seguinte da
# chave; a anterior fica (trigger). Auditoria care_line.template_changed só
# com ids (R18).
module CareLines
  module Templates
    module Save
      module_function

      def call(attrs, maintainer: nil)
        attrs = attrs.to_h.stringify_keys
        key = attrs["key"].to_s
        return fail(:invalid_key, "key") unless Catalog::TEMPLATE_KEYS.include?(key)
        return fail(:invalid_indicator, "indicator") unless attrs["indicator"] == Catalog::INDICATORS.fetch(key)

        name = attrs["name"].to_s
        return fail(:invalid_name, "name") unless name.strip == name && name.length.between?(1, 120)

        condition = attrs["declared_condition"]
        return fail(:invalid_declared_condition, "declaredCondition") unless condition.nil? || (Catalog::CONDITIONS - %w[none]).include?(condition)

        practices = Rules.practices(attrs["practices"], template: true)
        return practices if practices.failure?

        eligibility = Rules.eligibility(attrs["eligibility"])
        return eligibility if eligibility.failure?

        template = PlatformRecord.transaction do
          PlatformRecord.connection.execute("SELECT pg_advisory_xact_lock(#{Zlib.crc32("care_line_templates:#{key}")})")
          version = CareLineTemplate.where(key: key).maximum(:version).to_i + 1
          CareLineTemplate.create!(key: key, version: version, name: name, indicator: attrs["indicator"], declared_condition: condition,
                                   eligibility: eligibility.payload[:eligibility], practices: practices.payload[:practices],
                                   created_by_maintainer_id: maintainer&.id, created_at: Time.current)
        end
        Platform.audit("care_line.template_changed", care_line_template_id: template.id, template_key: key, version: template.version)
        Result.ok(template: template)
      end

      def fail(code, field) = Result.fail(code, details: { field: field })
      private_class_method :fail
    end
  end
end
