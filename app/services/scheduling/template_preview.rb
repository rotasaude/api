# Pré-visualização do modelo (spec §3.2; contratos §3, §10): aplica as faixas a
# um turno de amostra e devolve as faixas efetivas (recortadas pelo turno e
# pelo dia) e as vagas de cada faixa agendável cujo tipo serve o CBO da
# amostra. Nada é gravado; não desconta horário marcado nem o que já passou.
module Scheduling
  module TemplatePreview
    CBO = /\A\d{6}\z/

    module_function

    def call(blocks:, fit_in_limit:, sample:, catalog: AppointmentTypes.catalog, zone: Time.zone)
      detail = TemplateBlocks.detail(blocks, catalog)
      return Result.fail(:invalid_blocks, details: { detail: detail.to_s }) if detail
      return Result.fail(:invalid_fit_in_limit) unless SaveTemplate.valid_limit?(fit_in_limit)

      # normalize: Availability lê as faixas com chave em texto.
      shift = sample_shift(sample, TemplateBlocks.normalize(blocks), zone)
      return Result.fail(:invalid) unless shift

      types = catalog.active
      effective = Availability.blocks_for(shift, types: types, fallback: catalog.fallback, zone: zone)
      slots = effective.select { |b| b.kind == "bookable" }.flat_map do |block|
        type = types[block.appointment_type_key]
        next [] unless type&.serves?(shift.cbo_code)

        Availability.slice(block, block.slot_minutes || type.duration_minutes).map do |starts, ends|
          { starts_at: starts.iso8601, ends_at: ends.iso8601, appointment_type_key: type.key }
        end
      end
      Result.ok(slots: slots.sort_by { |s| s[:starts_at] }, blocks: BlockJson.list(effective, zone: zone, catalog: catalog))
    end

    def sample_shift(sample, blocks, zone)
      return nil unless sample.is_a?(Hash)

      sample = sample.stringify_keys
      return nil unless sample["cbo_code"].is_a?(String) && sample["cbo_code"].match?(CBO)

      starts = zone.iso8601(sample["starts_at"].to_s)
      ends = zone.iso8601(sample["ends_at"].to_s)
      return nil unless ends > starts && ends - starts <= ProfessionalShift::MAX_DURATION

      Availability::Shift.new(id: nil, professional_id: nil, starts_at: starts, ends_at: ends,
                              cbo_code: sample["cbo_code"], default_type_key: nil, blocks: blocks, cancelled: false)
    rescue ArgumentError
      nil
    end
  end
end
