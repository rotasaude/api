# Cadastra e edita leitos da observação da UPA (ADR 0050; contrato §3, §12 Q1).
# Criação: `health_unit_id` (UPA ativa) e `label` (1–20, sem os espaços das
# pontas), `active` opcional. Edição: `label` e `active`; a UPA do leito não
# muda. Unidade que não é UPA → not_an_upa; rótulo repetido na UPA →
# bed_label_taken (409, pelo índice único); desativar com estadia aberta →
# bed_occupied (409, sob o FOR UPDATE do leito). Nunca se apaga: desativa-se.
# Sem evento nem trilha (só cadastro, sem paciente). O padrão do
# Psychosocial::SaveBed.
module Urgency
  module SaveBed
    KEYS = %w[health_unit_id label active].freeze
    KEY_PATH_MAX = 64
    LABEL_INDEX = "idx_urgency_beds_label".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # -> Result.ok(bed:) | fail(:invalid_request | :not_an_upa | :bed_label_taken | :bed_occupied, details: { path:, problems: })
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

      UrgencyBed.transaction(requires_new: true) do
        record = bed || UrgencyBed.new(health_unit: unit)
        record.lock! if bed
        record.assign_attributes(label: label, active: values["active"])
        next Result.ok(bed: record) if bed && !record.changed?
        next refuse([ "active" ], :bed_occupied) if bed && record.active_changed?(to: false) && record.bed_stays.open_stays.exists?

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
      unit = id.is_a?(String) && id.match?(UUID) ? HealthUnit.find_by(id: id, active: true) : nil
      return [ nil, refuse([ "health_unit_id" ]) ] unless unit
      return [ nil, refuse([ "health_unit_id" ], :not_an_upa) ] unless unit.kind == "upa"

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
