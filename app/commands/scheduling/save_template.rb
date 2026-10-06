# Modelo de agenda (ADR 0029 §3.2; contratos §3, §9, §10). Só o municipal_admin
# chega aqui (controller). Edição parcial: o que não vem fica como está. Mudar o
# modelo nunca move horário marcado: as vagas são calculadas, e o horário
# guarda o que foi marcado (o que saiu da grade aparece com outside_template).
module Scheduling
  module SaveTemplate
    MAX_NAME = 60
    FIT_IN_LIMIT = (0..20)

    module_function

    def call(attrs:, by:, template: nil)
      template ||= ScheduleTemplate.new
      name = attrs.key?("name") ? attrs["name"] : template.name
      return Result.fail(:invalid_name) unless name.is_a?(String) && name.squish.length.between?(1, MAX_NAME)

      limit = attrs.key?("fit_in_limit") ? attrs["fit_in_limit"] : template.fit_in_limit
      return Result.fail(:invalid_fit_in_limit) unless valid_limit?(limit)

      blocks = attrs.key?("blocks") ? attrs["blocks"] : template.blocks
      detail = TemplateBlocks.detail(blocks, AppointmentTypes.catalog)
      return Result.fail(:invalid_blocks, details: { detail: detail.to_s }) if detail

      active = attrs.key?("active") ? attrs["active"] : template.active
      return Result.fail(:invalid) unless [ true, false ].include?(active)

      ApplicationRecord.transaction do
        template.update!(name: name.squish, fit_in_limit: limit, blocks: TemplateBlocks.normalize(blocks), active: active)
        DomainEvents.publish("schedule_template.changed", template_id: template.id, user_id: by.id)
      end
      Result.ok(template: template)
    end

    def valid_limit?(limit) = limit.is_a?(Integer) && FIT_IN_LIMIT.cover?(limit)
  end
end
