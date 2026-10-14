# Prazo por etapa (ADR 0036; spec §5): prestador × exame → catálogo →
# padrão da plataforma; urgente = metade arredondada para cima. Dias
# corridos no fuso da cidade (Time.zone é o da cidade dentro de
# CityConnection.with).
module Exams
  module Deadlines
    PLATFORM = { "authorize" => 15, "schedule" => 15, "collect" => 30, "result" => 30, "acknowledge" => 15 }.freeze
    STAGES = PLATFORM.keys.freeze

    module_function

    def days(stage:, sigtap_code:, provider_id:, priority:)
      raise ArgumentError, "etapa desconhecida: #{stage.inspect}" unless PLATFORM.key?(stage)

      item = ExamCatalogItem.find_by(sigtap_code: sigtap_code)
      own = provider_id && item && ExamProviderItem.find_by(exam_provider_id: provider_id, exam_catalog_item_id: item.id)
      base = own&.days_for(stage) || item&.days_for(stage) || PLATFORM.fetch(stage)
      priority == "urgent" ? (base / 2.0).ceil : base
    end

    def due_on(stage:, order:, opened_at:, provider_id: order.exam_provider_id)
      opened_at.in_time_zone.to_date + days(stage: stage, sigtap_code: order.sigtap_code, provider_id: provider_id,
                                            priority: order.priority)
    end
  end
end
