# Cadastra e edita leitos do acolhimento noturno (ADR 0049; contrato §3).
# Criação: `health_unit_id` (CAPS ativo) e `label` (1–20, sem os espaços das
# pontas), `active` opcional. Edição: `label` e `active`; o CAPS do leito não
# muda. Só CAPS de NIGHT_MODALITIES têm leito (caps_without_beds); rótulo
# repetido no CAPS → bed_label_taken (409, pelo índice único). Nunca se apaga:
# desativa-se. Sem evento (só cadastro, sem paciente).
module Psychosocial
  module SaveBed
    KEYS = %w[health_unit_id label active].freeze
    KEY_PATH_MAX = 64
    LABEL_INDEX = "idx_psychosocial_beds_label".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # -> Result.ok(bed:) | fail(:invalid_request | :caps_without_beds, details: { path:, problems: }) | fail(:bed_label_taken)
    def call(attrs:, by:, bed: nil)
      attrs = attrs.to_h.stringify_keys
      unknown = attrs.keys.reject { |key| KEYS.include?(key) }.map { |key| key[0, KEY_PATH_MAX] }
      return refuse(unknown) if unknown.any?

      unit, refusal = resolve_unit(attrs, bed)
      return refusal if refusal

      values = { "label" => bed&.label, "active" => bed ? bed.active : true }.merge(attrs.slice("label", "active"))
      label = values["label"].is_a?(String) ? values["label"].strip : nil
      bad = []
      bad << "label" unless label && Catalog::BED_LABEL.cover?(label.length)
      bad << "active" unless [ true, false ].include?(values["active"])
      return refuse(bad) if bad.any?

      PsychosocialBed.transaction(requires_new: true) do
        record = bed || PsychosocialBed.new(health_unit: unit)
        record.lock! if bed
        record.assign_attributes(label: label, active: values["active"])
        next Result.ok(bed: record) if bed && !record.changed?

        record.updated_by_user = by
        record.save!
        Result.ok(bed: record)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(LABEL_INDEX)

      refuse([ "label" ], :bed_label_taken)
    end

    # -> [HealthUnit, nil] | [nil, Result de recusa]. Na edição, `health_unit_id`
    # só é aceito igual ao do leito.
    def resolve_unit(attrs, bed)
      if bed
        moved = attrs.key?("health_unit_id") && attrs["health_unit_id"] != bed.health_unit_id
        return moved ? [ nil, refuse([ "health_unit_id" ]) ] : [ bed.health_unit, nil ]
      end

      id = attrs["health_unit_id"]
      unit = id.is_a?(String) && id.match?(UUID) ? HealthUnit.find_by(id: id, kind: "caps", active: true) : nil
      return [ nil, refuse([ "health_unit_id" ]) ] unless unit
      return [ nil, refuse([ "health_unit_id" ], :caps_without_beds) ] unless unit.night_capable?

      [ unit, nil ]
    end

    # Todas as recusas de uma vez; a primeira vai para o topo.
    def refuse(paths, error = :invalid_request)
      problems = paths.map { |path| { path: path, error: error.to_s } }
      Result.fail(error, details: { path: problems.first[:path], problems: problems })
    end

    private_class_method :resolve_unit, :refuse
  end
end
