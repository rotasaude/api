# As origens de ficha que regeram da fonte (ADR 0030/0031): a Produção e o
# "Reenviar" despacham por source_type.
module Ledi
  module FichaSources
    REGISTRY = { "Screening" => "Ledi::ScreeningFicha", "Consultation" => "Ledi::ConsultationFicha" }.freeze

    module_function

    def for(source_type) = REGISTRY[source_type.to_s]&.constantize

    def attendance_ids(failures)
      ids = failures.group_by(&:source_type).transform_values { |rows| rows.map(&:source_id) }
      Screening.where(id: ids.fetch("Screening", [])).pluck(:id, :attendance_id).to_h
               .merge(Consultation.where(id: ids.fetch("Consultation", [])).pluck(:id, :attendance_id).to_h)
    end
  end
end
