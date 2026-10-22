# Linhas da cidade (contrato §3). Adotar copia as regras da versão do
# catálogo-base; PATCH { template_version } readota (Desvio 12). Linha
# própria: as mesmas formas, validadas pelo Rules. Uma adoção por template
# e uma linha ativa por condição declarada (índices únicos).
module CareLines
  module SaveLine
    CUSTOM_KEYS = %w[name eligibility practices declared_condition active].freeze

    module_function

    def call(params:, by:, line: nil)
      params = params.to_h.stringify_keys
      if line.nil? && params.key?("template_key") then adopt(params, by)
      elsif line.nil? then custom(CareLine.new(source: "custom"), params, by)
      elsif line.template? then readopt(line, params, by)
      else custom(line, params, by)
      end
    rescue ActiveRecord::RecordNotUnique
      # Só a condição declarada chega aqui (adopt trata o seu): linha própria e readoção.
      Result.fail(:duplicate_declared_condition)
    end

    def adopt(params, by)
      template = CareLineTemplate.find_by(key: params["template_key"].to_s, version: params["template_version"])
      return Result.fail(:template_not_found) unless template

      # Antes do INSERT: a adoção repetida também fere o índice da condição declarada,
      # e o Postgres cita só um dos dois; o template é o motivo certo.
      return Result.fail(:duplicate_template) if CareLine.exists?(template_key: template.key)

      line = CareLine.new(source: "template", template_key: template.key, active: true)
      CareLine.transaction do
        copy!(line, template, by)
        DomainEvents.publish("care_line.adopted", care_line_id: line.id, user_id: by.id)
      end
      Result.ok(line: line, created: true)
    rescue ActiveRecord::RecordNotUnique
      # Corrida: o perdedor fere os dois índices únicos e o Postgres cita o primeiro na ordem
      # de OID (depende de dump x migração). Depois do commit do vencedor, a consulta decide.
      Result.fail(CareLine.exists?(template_key: template.key) ? :duplicate_template : :duplicate_declared_condition)
    end

    def readopt(line, params, by)
      return Result.fail(:immutable_rules) if (params.keys & %w[name eligibility practices declared_condition]).any?

      template = nil
      if params.key?("template_version")
        template = CareLineTemplate.find_by(key: line.template_key, version: params["template_version"])
        return Result.fail(:template_not_found) unless template
      end

      CareLine.transaction do
        if template
          copy!(line, template, by)
          DomainEvents.publish("care_line.adopted", care_line_id: line.id, user_id: by.id)
        end
        line.update!(active: params["active"] == true, updated_by_user: by) if params.key?("active")
      end
      Result.ok(line: line, created: false)
    end

    def custom(line, params, by)
      attrs = params.slice(*CUSTOM_KEYS)
      if line.new_record? || attrs.key?("name")
        name = attrs["name"].to_s
        return Result.fail(:invalid_name) unless name.strip == name && name.length.between?(1, 120)
      end
      if line.new_record? || attrs.key?("eligibility")
        eligibility = Rules.eligibility(attrs["eligibility"])
        return eligibility if eligibility.failure?

        attrs["eligibility"] = eligibility.payload[:eligibility]
      end
      if line.new_record? || attrs.key?("practices")
        practices = Rules.practices(attrs["practices"])
        return practices if practices.failure?

        attrs["practices"] = practices.payload[:practices]
      end
      condition = attrs["declared_condition"]
      return Result.fail(:invalid_declared_condition) unless condition.nil? || (Catalog::CONDITIONS - %w[none]).include?(condition)

      attrs["active"] = attrs["active"] == true if attrs.key?("active")
      created = line.new_record?
      line.assign_attributes(attrs.merge("updated_by_user" => by))
      line.save!
      Result.ok(line: line, created: created)
    end

    def copy!(line, template, by)
      line.assign_attributes(template_version: template.version, indicator: template.indicator, name: template.name,
                             eligibility: template.eligibility, practices: template.practices,
                             declared_condition: template.declared_condition, updated_by_user: by)
      line.save!
    end
    private_class_method :adopt, :readopt, :custom, :copy!
  end
end
