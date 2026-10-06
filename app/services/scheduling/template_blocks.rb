# Faixas do modelo (ADR 0029 §3.2; contratos §2, §3, §9, §10): `HH:MM` locais,
# fim depois do início no mesmo dia (sem 24:00), sem sobreposição (encostar
# vale), `bookable` exige tipo ativo, `slot_minutes` 5–240 só em `bookable`,
# no máximo 24 faixas. Chaves em texto ou símbolo; `normalize` grava texto.
module Scheduling
  module TemplateBlocks
    KINDS = %w[walk_in bookable blocked].freeze
    KEYS = %w[starts ends kind appointment_type_key slot_minutes].freeze
    TIME = /\A([01]\d|2[0-3]):[0-5]\d\z/
    MAX_BLOCKS = 24
    SLOT_MINUTES = (5..240)

    module_function

    def detail(blocks, catalog)
      return :bad_block unless blocks.is_a?(Array)
      return :empty if blocks.empty?
      return :bad_block if blocks.size > MAX_BLOCKS

      ranges = []
      blocks.each do |raw|
        return :bad_block unless raw.is_a?(Hash)

        block = raw.stringify_keys
        reason = block_detail(block, catalog)
        return reason if reason

        ranges << [ block["starts"], block["ends"] ]
      end
      # Ordenadas pelo início, basta comparar vizinhas ("HH:MM" ordena como texto).
      ranges.sort.each_cons(2).any? { |(_, ends), (starts, _)| starts < ends } ? :overlap : nil
    end

    def block_detail(block, catalog)
      return :bad_block unless (block.keys - KEYS).empty? && KINDS.include?(block["kind"])
      return :crosses_midnight if block["ends"] == "24:00"
      return :bad_time unless TIME.match?(block["starts"].to_s) && TIME.match?(block["ends"].to_s)
      return :crosses_midnight unless block["starts"] < block["ends"]

      bookable = block["kind"] == "bookable"
      return :bad_block if !bookable && (block.key?("appointment_type_key") || block.key?("slot_minutes"))
      return nil unless bookable
      return :missing_type if block["appointment_type_key"].blank?

      type = catalog.find(block["appointment_type_key"])
      return :unknown_type unless type
      return :inactive_type unless type.active

      minutes = block["slot_minutes"]
      return :bad_slot_minutes unless minutes.nil? || (minutes.is_a?(Integer) && SLOT_MINUTES.cover?(minutes))

      nil
    end

    def normalize(blocks) = blocks.map { |raw| raw.to_h.stringify_keys.slice(*KEYS) }
  end
end
