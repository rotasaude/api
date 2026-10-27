# Publica a versão seguinte da lista nacional (substituição completa: a nova
# versão pode tirar doenças). `expected_version` é a `version` da última
# publicada (agendada ou em vigor), 0 se não há: quem publica viu a lista que
# está substituindo. Auditoria só com ids e números (R18).
module Surveillance
  module DiseaseList
    module Publish
      module_function

      def call(ordinance:, effective_from:, diseases:, expected_version:, notes: nil, sources: nil, maintainer: nil)
        ordinance = ordinance.to_s
        return refuse("ordinance") unless ordinance.strip.present? && ordinance.length <= ORDINANCE_MAX
        return refuse("notes") unless notes.nil? || (notes.is_a?(String) && notes.length <= NOTES_MAX)
        return refuse("sources") unless sources.nil? || sources.is_a?(Hash)

        date = coerce_date(effective_from)
        return refuse("effective_from") if date.nil? || date < Time.zone.today

        checked = DiseaseList.validate(diseases)
        return checked if checked.failure?

        stale = false
        out_of_order = false
        record = DiseaseList.with_lock do
          last = DiseaseList.latest
          if expected_version != (last&.version || 0)
            stale = true
            next
          end
          if last && date < last.effective_from
            out_of_order = true
            next
          end

          DiseaseList.create_version!(version: (last&.version || 0) + 1, ordinance: ordinance, effective_from: date, diseases: diseases,
                                      notes: notes, sources: sources, maintainer_id: maintainer&.id)
        end
        return Result.fail(:stale_version) if stale
        return refuse("effective_from") if out_of_order

        Platform.audit("notifiable_disease_list.published", notifiable_disease_version_id: record.id, version: record.version,
                                                            diseases_count: record.diseases.count)
        Result.ok(version: record)
      end

      def coerce_date(value)
        return value if value.is_a?(Date) && !value.is_a?(DateTime)

        Date.iso8601(value.to_s) if value.is_a?(String)
      rescue Date::Error
        nil
      end

      def refuse(path) = DiseaseList.refuse(path)
      private_class_method :coerce_date, :refuse
    end
  end
end
